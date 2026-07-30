import shutil

pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
shutil.copyfile(pbxproj, pbxproj + ".bak")

with open(pbxproj, "r") as f:
    content = f.read()

# Transport-control PNGs for NowPlayingVC / MiniPlayerBar. Bundled as loose PNGs
# rather than in the asset catalog — Assets.car isn't reliably read by the iOS 6
# runtime.
names = []
for base in ["play", "pause", "play-small", "pause-small", "skip-back", "skip-forward", "x"]:
    names.append(base + ".png")
    names.append(base + "@2x.png")

files = []
for i, name in enumerate(names):
    files.append(("BB21%04d" % (i * 2 + 1), "BB21%04d" % (i * 2 + 2), name))

for ref, build, name in files:
    if ref in content:
        print("already present, skipping: " + name)
        continue
    content = content.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */"
    )
    content = content.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = image.png; path = \"{name}\"; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */"
    )
    content = content.replace(
        "\t\t\t\tBB150001 /* Logo@2x.png */,",
        f"\t\t\t\tBB150001 /* Logo@2x.png */,\n\t\t\t\t{ref} /* {name} */,"
    )
    content = content.replace(
        "\t\t\t\tBB150002 /* Logo@2x.png in Resources */,",
        f"\t\t\t\tBB150002 /* Logo@2x.png in Resources */,\n\t\t\t\t{build} /* {name} in Resources */,"
    )

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated: %d image(s)" % len(files))
