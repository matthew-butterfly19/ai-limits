# -*- coding: utf-8 -*-
"""Punkt wejścia: `menu`, `ingest`, `dashboard`."""

import sys


def main(argv=None):
    argv = list(argv if argv is not None else sys.argv[1:])
    cmd = argv[0] if argv else "menu"

    if cmd == "menu":
        from . import menu
        print(menu.render())
        return 0

    if cmd == "ingest":
        from . import ingest, store
        con = store.connect()
        print(ingest.ingest_all(con))
        return 0

    if cmd == "dashboard":
        from . import dashboard
        path = dashboard.write()
        if "--open" in argv:
            import subprocess
            subprocess.run(["/usr/bin/open", path])
        else:
            print(path)
        return 0

    print("użycie: ailimits [menu|ingest|dashboard [--open]]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
