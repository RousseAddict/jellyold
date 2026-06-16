import re

pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
with open(pbxproj, "r") as f:
    content = f.read()

new_files = [
    ("BB110001", "BB110002", "Library.swift"),
    ("BB110003", "BB110004", "MediaItem.swift"),
    ("BB110005", "BB110006", "AsyncImageView.swift"),
    ("BB110007", "BB110008", "PosterCell.swift"),
    ("BB110009", "BB11000A", "LibraryListVC.swift"),
    ("BB11000B", "BB11000C", "ItemListVC.swift"),
]

# Add PBXBuildFile entries
build_file_entries = ""
for ref_id, build_id, name in new_files:
    build_file_entries += f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n"
content = content.replace(
    "/* End PBXBuildFile section */",
    build_file_entries + "/* End PBXBuildFile section */"
)

# Add PBXFileReference entries
file_ref_entries = ""
for ref_id, build_id, name in new_files:
    file_ref_entries += f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n"
content = content.replace(
    "/* End PBXFileReference section */",
    file_ref_entries + "/* End PBXFileReference section */"
)

# Add to group children (after ServerSetupVC.swift line)
group_entries = ""
for ref_id, build_id, name in new_files:
    group_entries += f"\t\t\t\t{ref_id} /* {name} */,\n"
content = content.replace(
    "\t\t\t\tA34363202FD764290064ADE1 /* ServerSetupVC.swift */,",
    f"\t\t\t\tA34363202FD764290064ADE1 /* ServerSetupVC.swift */,\n{group_entries.rstrip()}"
)

# Add to PBXSourcesBuildPhase (after ServerSetupVC.swift in Sources)
sources_entries = ""
for ref_id, build_id, name in new_files:
    sources_entries += f"\t\t\t\t{build_id} /* {name} in Sources */,\n"
content = content.replace(
    "\t\t\t\tA34363212FD764290064ADE1 /* ServerSetupVC.swift in Sources */,",
    f"\t\t\t\tA34363212FD764290064ADE1 /* ServerSetupVC.swift in Sources */,\n{sources_entries.rstrip()}"
)

with open(pbxproj, "w") as f:
    f.write(content)

print("pbxproj updated")
