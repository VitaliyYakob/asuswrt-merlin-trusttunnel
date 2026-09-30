.PHONY: test preview package ipk browser-test lint screenshots

lint:
	shellcheck --severity=warning -x -P addon -P addon/lib -P tools addon/trusttunnel.sh tools/*.sh install.sh install-online.sh uninstall.sh build-ipk.sh addon/S99trusttunnel
	shellcheck --severity=warning -x packaging/*.sh

test:
	sh tools/test-cidr-compat.sh
	python3 -m unittest discover -s tests -v
	node --check addon/web/trusttunnel.js
	node tests/test_web.js
	node --check addon/web/connection.js
	node tests/test_connection.js
	node --check addon/web/transfer.js
	node tests/test_transfer.js

preview:
	python3 tools/make-preview.py

package:
	python3 tools/package.py

ipk:
	python3 tools/build-ipk.py --write-online

screenshots: preview
	node tools/capture-readme.js

browser-test: preview
	node tools/test-preview.js
	node tools/test-browser-transport.js
	node tools/test-browser-assets.js
