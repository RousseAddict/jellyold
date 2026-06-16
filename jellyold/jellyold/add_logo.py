pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
with open(pbxproj, "r") as f:
    content = f.read()

ref_id   = "BB150001"
build_id = "BB150002"
name     = "Logo@2x.png"

# PBXBuildFile
content = content.replace(
    "/* End PBXBuildFile section */",
    f"\t\t{build_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n/* End PBXBuildFile section */"
)
# PBXFileReference
content = content.replace(
    "/* End PBXFileReference section */",
    f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = image.png; path = \"{name}\"; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */"
)
# Add to group children (after Default-568h@2x.png)
content = content.replace(
    "\t\t\t\tA34363002FD764270064ADE1 /* Default-568h@2x.png */,",
    f"\t\t\t\tA34363002FD764270064ADE1 /* Default-568h@2x.png */,\n\t\t\t\t{ref_id} /* {name} */,"
)
# Add to PBXResourcesBuildPhase (main app target)
content = content.replace(
    "\t\t\t\tA34363012FD764270064ADE1 /* Default-568h@2x.png in Resources */,",
    f"\t\t\t\tA34363012FD764270064ADE1 /* Default-568h@2x.png in Resources */,\n\t\t\t\t{build_id} /* {name} in Resources */,"
)

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated")
