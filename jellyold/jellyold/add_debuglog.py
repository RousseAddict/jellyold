pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
with open(pbxproj, "r") as f:
    content = f.read()

ref, build, name = "BB180001", "BB180002", "DebugLog.swift"

content = content.replace(
    "/* End PBXBuildFile section */",
    f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */"
)
content = content.replace(
    "/* End PBXFileReference section */",
    f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */"
)
content = content.replace(
    "\t\t\t\tBB160001 /* curl_bridge.c */,",
    f"\t\t\t\tBB160001 /* curl_bridge.c */,\n\t\t\t\t{ref} /* {name} */,"
)
content = content.replace(
    "\t\t\t\tBB160002 /* curl_bridge.c in Sources */,",
    f"\t\t\t\tBB160002 /* curl_bridge.c in Sources */,\n\t\t\t\t{build} /* {name} in Sources */,"
)

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated")
