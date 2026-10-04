#!/usr/bin/env bash
# The recorder launches a binary with no arguments, and an editor with no file
# open is not much of a demo. This opens a scratch copy of a real Odin source
# file, so the demo edits /tmp and never the repository.
set -e
SRC=/tmp/palmy-editor-demo.odin
cp -f /home/alex/Work/palmy/palmy/widgets.odin "$SRC"
exec /home/alex/Work/palmy/apps/editor/editor.bin "$SRC"
