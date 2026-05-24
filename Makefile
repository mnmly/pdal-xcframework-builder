PDAL_VERSION   ?=
LIBE57_VERSION ?=

.PHONY: xcframework release e57-xcframework e57-release \
        clean distclean check-version check-e57-version

xcframework: check-version
	./build.sh $(PDAL_VERSION)

release: check-version
	RELEASE=1 ./build.sh $(PDAL_VERSION)

# Self-contained libE57Format.xcframework (Xerces-C built into a sandbox
# prefix and bundled in). Independent of the pdalcpp build — used by
# SwiftPDAL's libE57Format → writers.copc bypass for PDAL's broken E57
# reader on multi-scan files.
e57-xcframework: check-e57-version
	./build_e57.sh $(LIBE57_VERSION)

e57-release: check-e57-version
	RELEASE=1 ./build_e57.sh $(LIBE57_VERSION)

check-version:
	@if [ -z "$(PDAL_VERSION)" ]; then \
		echo "Usage: make PDAL_VERSION=2.10.1 [xcframework|release]"; \
		exit 1; \
	fi

check-e57-version:
	@if [ -z "$(LIBE57_VERSION)" ]; then \
		echo "Usage: make LIBE57_VERSION=3.3.0 [e57-xcframework|e57-release]"; \
		exit 1; \
	fi

clean:
	rm -rf work

distclean: clean
	rm -rf output
