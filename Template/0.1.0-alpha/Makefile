.PHONY: test preview package

test:
	python3 -m unittest discover -s tests -v
	node --check addon/web/trusttunnel.js
	node tests/test_web.js

preview:
	python3 tools/make-preview.py

package:
	python3 tools/package.py
