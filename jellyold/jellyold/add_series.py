pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
with open(pbxproj, "r") as f:
    content = f.read()

new_files = [
    ("BB140001", "BB140002", "SeasonListVC.swift"),
    ("BB140003", "BB140004", "EpisodeListVC.swift"),
]

for ref_id, build_id, name in new_files:
    content = content.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n/* End PBXBuildFile section */"
    )
    content = content.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */"
    )
    content = content.replace(
        "\t\t\t\tBB130001 /* VideoPlayerVC.swift */,",
        f"\t\t\t\tBB130001 /* VideoPlayerVC.swift */,\n\t\t\t\t{ref_id} /* {name} */,"
    )
    content = content.replace(
        "\t\t\t\tBB130002 /* VideoPlayerVC.swift in Sources */,",
        f"\t\t\t\tBB130002 /* VideoPlayerVC.swift in Sources */,\n\t\t\t\t{build_id} /* {name} in Sources */,"
    )

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated")
