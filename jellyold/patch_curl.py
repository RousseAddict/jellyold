#!/usr/bin/env python3
# Integrates libcurl + OpenSSL (CurlFetcher) into the jellyold app target.
import sys

pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
with open(pbxproj, "r") as f:
    content = f.read()

if "CurlFetcher.swift" in content:
    print("curl integration already present — nothing to do")
    sys.exit(0)

# (fileRef, buildFile, name, fileType, in_sources, extra_buildfile_settings)
files = [
    ("BB160001", "BB160002", "curl_bridge.c",    "sourcecode.c.c",   True,  ""),
    ("BB160003", "BB160004", "CurlFetcher.swift", "sourcecode.swift", True,  ""),
    ("BB160005", "BB160006", "atomic_stubs.c",   "sourcecode.c.c",   True,  " settings = {COMPILER_FLAGS = \"-fno-builtin\"; };"),
    ("BB160007", "BB160008", "atomic_stubs.S",   "sourcecode.asm",   True,  ""),
]

for ref_id, build_id, name, ftype, in_src, extra in files:
    content = content.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */;{extra} }};\n/* End PBXBuildFile section */"
    )
    content = content.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */"
    )
    # group children — anchor on an existing group child line (unique to the group)
    content = content.replace(
        "\t\t\t\tBB140001 /* SeasonListVC.swift */,",
        f"\t\t\t\tBB140001 /* SeasonListVC.swift */,\n\t\t\t\t{ref_id} /* {name} */,"
    )
    if in_src:
        content = content.replace(
            "\t\t\t\tBB140002 /* SeasonListVC.swift in Sources */,",
            f"\t\t\t\tBB140002 /* SeasonListVC.swift in Sources */,\n\t\t\t\t{build_id} /* {name} in Sources */,"
        )

# Build settings on the app target (Debug + Release) — both lines are
# "rousseaddict.jellyold;" (the test targets use jellyoldTests/jellyoldUITests).
settings_block = (
    "\t\t\t\tHEADER_SEARCH_PATHS = \"$(SRCROOT)/ThirdParty/curl/include\";\n"
    "\t\t\t\tLIBRARY_SEARCH_PATHS = \"$(SRCROOT)/ThirdParty/curl/lib\";\n"
    "\t\t\t\tOTHER_LDFLAGS = \"-lcurl -lssl -lcrypto -lz\";\n"
    "\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = \"jellyold/jellyold-Bridging-Header.h\";\n"
)
anchor = "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = rousseaddict.jellyold;\n"
count = content.count(anchor)
if count != 2:
    print(f"ERROR: expected 2 app-target bundle-id lines, found {count}")
    sys.exit(1)
content = content.replace(anchor, settings_block + anchor)

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated: curl_bridge.c, CurlFetcher.swift, atomic_stubs.c/.S + build settings")
