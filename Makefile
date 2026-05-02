PDAL_VERSION ?=

.PHONY: xcframework release clean distclean check-version

xcframework: check-version
	./build.sh $(PDAL_VERSION)

release: check-version
	RELEASE=1 ./build.sh $(PDAL_VERSION)

check-version:
	@if [ -z "$(PDAL_VERSION)" ]; then \
		echo "Usage: make PDAL_VERSION=2.10.1 [xcframework|release]"; \
		exit 1; \
	fi

clean:
	rm -rf work

distclean: clean
	rm -rf output
