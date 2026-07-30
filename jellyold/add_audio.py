import shutil

pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
shutil.copyfile(pbxproj, pbxproj + ".bak")

with open(pbxproj, "r") as f:
    content = f.read()

files = [
    ("BB200001", "BB200002", "AudioPlayer.swift"),
    ("BB200003", "BB200004", "AudioQueue.swift"),
    ("BB200005", "BB200006", "NowPlayingVC.swift"),
    ("BB200007", "BB200008", "QueueVC.swift"),
    ("BB200009", "BB200010", "MiniPlayerBar.swift"),
]

for ref, build, name in files:
    if ref in content:
        print("already present, skipping: " + name)
        continue
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
