# mediaremote-adapter

From https://github.com/ungive/mediaremote-adapter, tag v0.7.7 (commit e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6), BSD 3-Clause (`LICENSE`). Copied as is: `bin/`, `include/`, and `src/` without its test client (`src/test/` and `src/adapter/test.m`; the script's `test` function is not used).

Kay uses it for `MediaPause`. Since macOS 15.4 MediaRemote only answers Apple-entitled processes, and `/usr/bin/perl` is one: the script loads this framework into perl, which then reads what is playing and sends play or pause. `macOS/scripts/build-app.sh` compiles `src/` into `Contents/Frameworks/MediaRemoteAdapter.framework` and copies the script to `Contents/Resources/`.

To update, copy a newer tag's same folders over these and change the tag above.
