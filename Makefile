.PHONY: test preview package browser-test

test:
	python3 -m unittest discover -s tests -v
	node --check addon/web/trusttunnel.js
	node tests/test_web.js
	node --check addon/web/connection.js
	node tests/test_connection.js

preview:
	python3 tools/make-preview.py

package:
	python3 tools/package.py

browser-test: preview
	node tools/test-preview.js
