import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "GelLink.xcodeproj"
OBJECTS = {}


def identifier(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(reference_name, kind, **properties):
    reference = identifier(reference_name)
    OBJECTS[reference] = {"isa": kind, **properties}
    return reference


def serialize(value, level=0):
    indentation = "\t" * level
    if isinstance(value, dict):
        lines = ["{"]
        for key, child in value.items():
            lines.append(f"{indentation}\t{json.dumps(key)} = {serialize(child, level + 1)};")
        lines.append(indentation + "}")
        return "\n".join(lines)
    if isinstance(value, list):
        lines = ["("]
        lines.extend(f"{indentation}\t{serialize(child, level + 1)}," for child in value)
        lines.append(indentation + ")")
        return "\n".join(lines)
    return json.dumps(str(value), ensure_ascii=False)


def configurations(name, settings, configuration_file=None):
    references = []
    for mode in ("Debug", "Release"):
        properties = {"name": mode, "buildSettings": {**settings,
                      "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O"}}
        if configuration_file is not None:
            properties["baseConfigurationReference"] = configuration_file
        references.append(add(f"{name}-{mode}", "XCBuildConfiguration", **properties))
    return add(f"{name}-configs", "XCConfigurationList", buildConfigurations=references,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def source_files():
    groups = []
    sources = {}
    for folder in ("Core", "Shared", "iOS", "Watch", "Config"):
        children = []
        for path in sorted((ROOT / folder).iterdir()):
            if folder == "iOS" and path.is_dir() and path.name == "Models":
                model_children = []
                for model_path in sorted(path.iterdir()):
                    if model_path.suffix not in (".mlmodel", ".json"):
                        continue
                    reference = add(str(model_path.relative_to(ROOT)), "PBXFileReference",
                                    lastKnownFileType="file.mlmodel" if model_path.suffix == ".mlmodel" else "text.json",
                                    path=model_path.name, sourceTree="<group>")
                    model_children.append(reference)
                    if model_path.suffix == ".mlmodel":
                        sources[str(model_path.relative_to(ROOT))] = reference
                children.append(add("group-models", "PBXGroup", children=model_children, path="Models", sourceTree="<group>"))
                continue
            if path.is_dir() and path.suffix == ".xcassets":
                children.append(add(str(path.relative_to(ROOT)), "PBXFileReference", lastKnownFileType="folder.assetcatalog",
                                    path=path.name, sourceTree="<group>"))
                continue
            if not path.is_file():
                continue
            if path.name == "Local.xcconfig":
                continue
            file_type = {".swift": "sourcecode.swift", ".xcconfig": "text.xcconfig"}.get(path.suffix, "text.plist.xml")
            reference = add(str(path.relative_to(ROOT)), "PBXFileReference", lastKnownFileType=file_type,
                            path=path.name, sourceTree="<group>")
            children.append(reference)
            if path.suffix == ".swift":
                sources[str(path.relative_to(ROOT))] = reference
        groups.append(add(f"group-{folder}", "PBXGroup", children=children, path=folder, sourceTree="<group>"))
    return groups, sources


def target(name, folder, sources, product, settings, extra_phases=None, dependencies=None, package_products=None):
    builds = [add(f"{name}-{path}-build", "PBXBuildFile", fileRef=reference)
              for path, reference in sources.items() if path.split("/")[0] in ("Core", "Shared", folder)]
    source_phase = add(f"{name}-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                       files=builds, runOnlyForDeploymentPostprocessing=0)
    asset_build = add(f"{name}-assets-build", "PBXBuildFile", fileRef=identifier(f"{folder}/Assets.xcassets"))
    resource_builds = [asset_build]
    if folder == "iOS":
        resource_builds.append(add("ios-emotion-metadata-build", "PBXBuildFile",
                                  fileRef=identifier("iOS/Models/VoiceCircumplex.json")))
    resources = add(f"{name}-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                    files=resource_builds, runOnlyForDeploymentPostprocessing=0)
    package_builds = [add(f"{name}-package-{reference}", "PBXBuildFile", productRef=reference)
                      for reference in (package_products or [])]
    frameworks = add(f"{name}-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                     files=package_builds, runOnlyForDeploymentPostprocessing=0)
    return add(f"target-{name}", "PBXNativeTarget", name=name, productName=name, productReference=product,
               productType="com.apple.product-type.application",
               buildConfigurationList=configurations(name, settings),
               buildPhases=[source_phase, frameworks, resources, *(extra_phases or [])],
               buildRules=[], dependencies=dependencies or [], packageProductDependencies=package_products or [])


def scheme(name, target_id, product):
    root = ET.Element("Scheme", LastUpgradeVersion="1640", version="1.3")

    def buildable(parent):
        return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary",
                             BlueprintIdentifier=target_id, BuildableName=product,
                             BlueprintName=name, ReferencedContainer="container:GelLink.xcodeproj")

    action = ET.SubElement(root, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(action, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES",
                          buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
    buildable(entry)
    ET.SubElement(root, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                  selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    launch = ET.SubElement(root, "LaunchAction", buildConfiguration="Debug",
                           selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0",
                           useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO",
                           debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
    buildable(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    profile = ET.SubElement(root, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES",
                            savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ET.SubElement(root, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(root, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    directory = PROJECT / "xcshareddata" / "xcschemes"
    directory.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(directory / f"{name}.xcscheme", encoding="UTF-8", xml_declaration=True)


def main():
    groups, sources = source_files()
    whisper_package = add("package-whisperkit", "XCRemoteSwiftPackageReference",
                          repositoryURL="https://github.com/argmaxinc/argmax-oss-swift.git",
                          requirement={"kind": "exactVersion", "version": "1.1.0"})
    whisper_product = add("product-whisperkit", "XCSwiftPackageProductDependency",
                          package=whisper_package, productName="WhisperKit")
    ios_product = add("product-ios", "PBXFileReference", explicitFileType="wrapper.application",
                      includeInIndex=0, path="GelLink.app", sourceTree="BUILT_PRODUCTS_DIR")
    watch_product = add("product-watch", "PBXFileReference", explicitFileType="wrapper.application",
                        includeInIndex=0, path="GelLinkWatch.app", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("products", "PBXGroup", children=[ios_product, watch_product], name="Products", sourceTree="<group>")
    main_group = add("main", "PBXGroup", children=[*groups, products], sourceTree="<group>")
    common = {"SWIFT_VERSION": "5.0", "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "5",
              "MARKETING_VERSION": "0.3.2", "GENERATE_INFOPLIST_FILE": "NO",
              "CODE_SIGN_ENTITLEMENTS": "Config/HealthKit.entitlements",
              "PRODUCT_NAME": "$(TARGET_NAME)", "ENABLE_PREVIEWS": "YES"}
    common["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    watch = target("GelLinkWatch", "Watch", sources, watch_product, {
        **common, "SDKROOT": "watchos", "SUPPORTED_PLATFORMS": "watchos watchsimulator",
        "WATCHOS_DEPLOYMENT_TARGET": "10.0", "TARGETED_DEVICE_FAMILY": "4",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(GELLINK_BUNDLE_ID).watchapp", "INFOPLIST_FILE": "Config/Watch-Info.plist",
        "SKIP_INSTALL": "YES"})
    proxy = add("watch-proxy", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1,
                remoteGlobalIDString=watch, remoteInfo="GelLinkWatch")
    dependency = add("watch-dependency", "PBXTargetDependency", target=watch, targetProxy=proxy)
    embed_build = add("embed-watch-build", "PBXBuildFile", fileRef=watch_product,
                      settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
    embed = add("embed-watch", "PBXCopyFilesBuildPhase", name="Embed Watch Content", buildActionMask=2147483647,
                dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16, files=[embed_build],
                runOnlyForDeploymentPostprocessing=0)
    ios = target("GelLink", "iOS", sources, ios_product, {
        **common, "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1,2",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(GELLINK_BUNDLE_ID)", "INFOPLIST_FILE": "Config/iOS-Info.plist"},
        extra_phases=[embed], dependencies=[dependency], package_products=[whisper_product])
    project_config = configurations("project", {
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"}, configuration_file=identifier("Config/Defaults.xcconfig"))
    project_id = add("project", "PBXProject", attributes={"LastUpgradeCheck": "1640", "LastSwiftUpdateCheck": "1640",
        "TargetAttributes": {ios: {"CreatedOnToolsVersion": "16.4", "SystemCapabilities": {"com.apple.HealthKit": {"enabled": 1}}},
                             watch: {"CreatedOnToolsVersion": "16.4", "SystemCapabilities": {"com.apple.HealthKit": {"enabled": 1}}}}},
        buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0", developmentRegion="ja",
        hasScannedForEncodings=0, knownRegions=["ja", "en", "Base"], mainGroup=main_group,
        productRefGroup=products, projectDirPath="", projectRoot="", targets=[ios, watch],
        packageReferences=[whisper_package])
    PROJECT.mkdir(exist_ok=True)
    content = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": OBJECTS, "rootObject": project_id}
    (PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(content) + "\n")
    workspace = PROJECT / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"/></Workspace>\n')
    scheme("GelLink", ios, "GelLink.app")
    scheme("GelLinkWatch", watch, "GelLinkWatch.app")
    print(PROJECT)


if __name__ == "__main__":
    main()
