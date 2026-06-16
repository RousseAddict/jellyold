pbxproj = "/Users/srv-admin/Documents/ios6-app/jellyold/jellyold/jellyold.xcodeproj/project.pbxproj"
with open(pbxproj, "r") as f:
    content = f.read()

# --- VideoPlayerVC.swift ---
vc_ref  = "BB130001"
vc_build = "BB130002"
vc_name  = "VideoPlayerVC.swift"

content = content.replace(
    "/* End PBXBuildFile section */",
    f"\t\t{vc_build} /* {vc_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {vc_ref} /* {vc_name} */; }};\n/* End PBXBuildFile section */"
)
content = content.replace(
    "/* End PBXFileReference section */",
    f"\t\t{vc_ref} /* {vc_name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {vc_name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */"
)
content = content.replace(
    "\t\t\t\tBB120001 /* ItemDetailVC.swift */,",
    f"\t\t\t\tBB120001 /* ItemDetailVC.swift */,\n\t\t\t\t{vc_ref} /* {vc_name} */,"
)
content = content.replace(
    "\t\t\t\tBB120002 /* ItemDetailVC.swift in Sources */,",
    f"\t\t\t\tBB120002 /* ItemDetailVC.swift in Sources */,\n\t\t\t\t{vc_build} /* {vc_name} in Sources */,"
)

# --- MediaPlayer.framework ---
fw_ref   = "BB130003"
fw_build = "BB130004"

content = content.replace(
    "/* End PBXBuildFile section */",
    f"\t\t{fw_build} /* MediaPlayer.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {fw_ref} /* MediaPlayer.framework */; }};\n/* End PBXBuildFile section */"
)
content = content.replace(
    "/* End PBXFileReference section */",
    f"\t\t{fw_ref} /* MediaPlayer.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = MediaPlayer.framework; path = System/Library/Frameworks/MediaPlayer.framework; sourceTree = SDKROOT; }};\n/* End PBXFileReference section */"
)
# Add to main app's PBXFrameworksBuildPhase (A34362CF)
content = content.replace(
    "A34362CF2FD764210064ADE1 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);",
    f"A34362CF2FD764210064ADE1 /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{fw_build} /* MediaPlayer.framework in Frameworks */,\n\t\t\t);"
)

with open(pbxproj, "w") as f:
    f.write(content)
print("pbxproj updated")
