#!/usr/bin/env python3
import sys
from pathlib import Path
from platform import gh, read, Failure
c = read(sys.argv[1])['config']
key = 'XENOMIT_ACTIVE_ENVIRONMENT'
path = '/repos/xenomit-do/xenomit-platform/actions/variables/' + key
owner = gh(path, c, optional=True)
if owner and owner['value'] != Path(sys.argv[2]).read_text().strip():
    raise Failure('Ownership differs; refusing to release another environment')
if owner:
    gh(path, c, method='DELETE')
