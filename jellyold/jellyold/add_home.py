import shutil

pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
shutil.copyfile(pbxproj, pbxproj + ".bak")

with open(pbxproj, "r") as f:
    content = f.read()

files = [
    ("BB260001", "BB260002", "ItemRouter.swift"),
    ("BB260003", "BB260004", "HomeVC.swift"),
    ("BB260005", "BB260006", "ShelfCell.swift"),
]

for ref, build, name in files:
    if ref in content:
        print("skip (already present): " + name)
        continue
    content = content.replace(
        "/* End PBXBuildFile section */",
        "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n/* End PBXBuildFile section */" % (build, name, ref, name)
    )
    content = content.replace(
        "/* End PBXFileReference section */",
        "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };\n/* End PBXFileReference section */" % (ref, name, name)
    )
    content = content.replace(
        "\t\t\t\tBB160001 /* curl_bridge.c */,",
        "\t\t\t\tBB160001 /* curl_bridge.c */,\n\t\t\t\t%s /* %s */," % (ref, name)
    )
    content = content.replace(
        "\t\t\t\tBB160002 /* curl_bridge.c in Sources */,",
        "\t\t\t\tBB160002 /* curl_bridge.c in Sources */,\n\t\t\t\t%s /* %s in Sources */," % (build, name)
    )

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated")
