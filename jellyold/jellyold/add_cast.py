import shutil

pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
shutil.copyfile(pbxproj, pbxproj + ".bak")

with open(pbxproj, "r") as f:
    content = f.read()

# Swift sources -> Sources build phase
sources = [
    ("BB230001", "BB230002", "CastMessage.swift"),
    ("BB230003", "BB230004", "CastDiscovery.swift"),
    ("BB230005", "BB230006", "CastSession.swift"),
    ("BB230007", "BB230008", "CastController.swift"),
    ("BB230009", "BB230010", "CastVC.swift"),
]

# Loose PNGs -> Resources build phase (not an asset catalog: Assets.car isn't
# reliably read by the iOS 6 runtime)
resources = [
    ("BB230011", "BB230012", "cast.png"),
    ("BB230013", "BB230014", "cast@2x.png"),
]

for ref, build, name in sources:
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

for ref, build, name in resources:
    if ref in content:
        print("skip (already present): " + name)
        continue
    content = content.replace(
        "/* End PBXBuildFile section */",
        "\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n/* End PBXBuildFile section */" % (build, name, ref, name)
    )
    content = content.replace(
        "/* End PBXFileReference section */",
        "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = image.png; path = \"%s\"; sourceTree = \"<group>\"; };\n/* End PBXFileReference section */" % (ref, name, name)
    )
    content = content.replace(
        "\t\t\t\tBB150001 /* Logo@2x.png */,",
        "\t\t\t\tBB150001 /* Logo@2x.png */,\n\t\t\t\t%s /* %s */," % (ref, name)
    )
    content = content.replace(
        "\t\t\t\tBB150002 /* Logo@2x.png in Resources */,",
        "\t\t\t\tBB150002 /* Logo@2x.png in Resources */,\n\t\t\t\t%s /* %s in Resources */," % (build, name)
    )

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated")
