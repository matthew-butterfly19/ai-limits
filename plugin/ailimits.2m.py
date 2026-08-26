#!/usr/bin/python3
# -*- coding: utf-8 -*-
# <bitbar.title>AI limits</bitbar.title>
# <bitbar.desc>Limity i zużycie tokenów Claude Code oraz Codeksa</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

import os
import sys

sys.path.insert(0, os.path.expanduser("~/Projects/ai-limits"))

try:
    from ailimits.cli import main
    sys.exit(main(["menu"]))
except SystemExit:
    raise
except Exception as exc:                     # pasek nie może zniknąć przez błąd w kodzie
    print("AI limits ✕")
    print("---")
    print("%s: %s" % (exc.__class__.__name__, exc))
    import traceback
    for line in traceback.format_exc().splitlines()[-6:]:
        print("--%s| font=Menlo size=11" % line.replace("|", "/"))
    sys.exit(0)
