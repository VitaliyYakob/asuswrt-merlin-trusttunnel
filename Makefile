.PHONY: test preview package browser-test lint

lint:
	shellcheck --severity=warning -x -P addon -P addon/lib addon/trusttunnel.sh tools/*.sh install.sh uninstall.sh addon/S99trusttunnel

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

browser-test: preview
	node tools/test-preview.js
	node tools/test-browser-transport.js
