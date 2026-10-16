# ddcx + hdr — build with swiftc from the shared Sources/ tree.
# Sources/DDC.swift + Sources/HDR.swift are also compiled by the MonitorApp
# Xcode target via MonitorApp/MonitorApp/SharedSources (symlink → ../../Sources);
# keep them free of top-level code (CLI fronts are @main under cli/).
#
# NOTE: cli front basenames must not case-collide with Sources/ basenames —
# swiftc's batch-mode objects are named after file basenames and APFS is
# case-insensitive (cli/hdr.swift vs Sources/HDR.swift overwrote each other).

DDC_SRC = Sources/DDC.swift Sources/HDR.swift
SWIFT = xcrun swiftc

all: ddcx hdr

ddcx: cli/ddcx-cli.swift $(DDC_SRC)
	$(SWIFT) -O -parse-as-library -o ddcx cli/ddcx-cli.swift $(DDC_SRC)

hdr: cli/hdr-cli.swift Sources/HDR.swift
	$(SWIFT) -O -parse-as-library -o hdr cli/hdr-cli.swift Sources/HDR.swift

clean:
	rm -f ddcx hdr

.PHONY: all clean
