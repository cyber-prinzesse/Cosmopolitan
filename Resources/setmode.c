/* setmode WIDTH HEIGHT | setmode reset
   Rebuild: x86_64-w64-mingw32-gcc -O2 -s Resources/setmode.c -o Resources/setmode.exe (Homebrew mingw-w64).
   Switches the bottle's (emulated) primary screen the way a game's ChangeDisplaySettingsEx does, without saving it;
   "setmode reset" returns to the saved mode. Used by Cosmopolitan's MacBook Air mode while a game runs.
   Exit 0 = DISP_CHANGE_SUCCESSFUL. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    LONG r;
    DEVMODEW c = {.dmSize = sizeof(c)};

    if (argc == 2 && !strcmp(argv[1], "reset"))
        r = ChangeDisplaySettingsExW(NULL, NULL, NULL, 0, NULL);
    else if (argc == 3)
    {
        DEVMODEW m = {.dmSize = sizeof(m)};
        m.dmPelsWidth = atoi(argv[1]);
        m.dmPelsHeight = atoi(argv[2]);
        m.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
        r = ChangeDisplaySettingsExW(NULL, &m, NULL, 0, NULL);
    }
    else
    {
        fprintf(stderr, "usage: setmode WIDTH HEIGHT | setmode reset\n");
        return 2;
    }
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &c);
    printf("result %ld, current %lux%lu\n", r, c.dmPelsWidth, c.dmPelsHeight);
    return r == DISP_CHANGE_SUCCESSFUL ? 0 : 1;
}
