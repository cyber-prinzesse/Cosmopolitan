import SwiftUI

extension Model {
    // Shell snippet: clone the template's GStreamer.framework once, then symlink the media modules' missing @rpath libs to it.
    // Symlinks (not copies) so plugins and winegstreamer share one loaded copy of each library.
    nonisolated static func linkGStreamer(unix: String, templateFrameworks fw: String) -> String {
        let g = support + "/engines/gstreamer/GStreamer.framework", gl = g + "/Versions/1.0/lib"
        return "mkdir -p \(shq("\(support)/engines/gstreamer")); [ -d \(shq("\(g)")) ] || cp -cR \(shq("\(fw)/GStreamer.framework")) \(shq("\(g)")); cd \(shq("\(unix)")) && for f in winegstreamer.so winedmo.so; do otool -L $f | awk '/@rpath/{print $1}' | sed 's|@rpath/||' | while read x; do [ -e \"$x\" ] || { [ -e \(shq("\(gl)/"))\"$x\" ] && ln -s \(shq("\(gl)/"))\"$x\" \"$x\"; }; done; done; true"
    }
    // Sikarugir engines aren't self-contained: give a freshly unpacked one the same fix-ups the working 10.0_8 engine has.
    nonisolated static func prepareEngine(_ e: String) -> String {
        guard let app = Pins.verifiedTemplate() else { return "✗ the pinned Sikarugir template \(Pins.sikarugirTemplate) is missing or doesn't match its pins; engine left as is\n" }
        let fw = "\(app)/Contents/Frameworks", unix = "\(e)/lib/wine/x86_64-unix"
        _ = shell("cp -cR \(shq("\(fw)"))/*.dylib \(shq("\(unix)/")) 2>/dev/null; cp -c \(shq("\(fw)/libinotify.0.dylib")) \(shq("\(e)/bin/inotify.dylib"))")
        _ = shell(linkGStreamer(unix: unix, templateFrameworks: fw))
        // wineserver has no header padding for add_rpath; a same-or-shorter -change is the only option, and DYLD_* never reaches it.
        _ = shell("install_name_tool -change @rpath/libinotify.0.dylib @executable_path/inotify.dylib \(shq("\(e)/bin/wineserver")) 2>/dev/null; codesign --force -s - \(shq("\(e)/bin/wineserver")) 2>/dev/null")
        let icd = "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"\(unix)/libMVK.dylib\",\"api_version\":\"1.4.0\",\"is_portability_driver\":false}}"
        try? icd.write(toFile: "\(e)/MoltenVK_icd.json", atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: "\(e)/dxmt_extescape", contents: nil)
        if !engineHasDockPatches(((e as NSString).deletingLastPathComponent as NSString).lastPathComponent) { _ = installNoDockAddon(e) }
        let v = shell("\(shq("\(e)/bin/wine")) --version 2>&1 | head -1")
        return v.hasPrefix("wine-") ? "  prepared (\(v), dylibs from \(Pins.sikarugirTemplate))\n" : "  prepared, but wine --version failed: \(v.prefix(80))\n"
    }
}
