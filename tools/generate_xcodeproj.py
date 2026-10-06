#!/usr/bin/env python3
"""Generate GreenCordHandbook.xcodeproj from the source tree.

    python3 tools/generate_xcodeproj.py

The project file is generated rather than hand-edited so that adding a Swift
file means dropping it in a directory and re-running this. Everything it
produces is deterministic: object ids are derived from a hash of each object's
role, so regenerating does not churn the file.

Targets:
  GreenCordHandbook          the app        (iOS 17.0+, iPhone + iPad)
  GreenCordHandbookTests     unit tests     (Swift Testing)
  GreenCordHandbookUITests   UI tests       (XCTest)
"""
import hashlib
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_NAME = "GreenCordHandbook"
BUNDLE_ID = os.environ.get("GREENCORD_BUNDLE_ID", "net.princetonisd.pshs.greencord")
# Empty by default: the simulator does not need it. To run on a real phone, set
# GREENCORD_TEAM_ID to the ten-character team id from the Apple ID you sign in
# with in Xcode, then re-run this script.
TEAM_ID = os.environ.get("GREENCORD_TEAM_ID", "")
# The address the Run action points the app at. Loopback suits the Simulator.
# For a physical phone, regenerate with this set to the Mac's LAN address -
# a phone reading 127.0.0.1 looks at itself and never finds the server.
BACKEND_URL = os.environ.get("GREENCORD_BACKEND_URL", "https://127.0.0.1:8443")
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"

APP_DIR = "GreenCordHandbook"
TEST_DIR = "GreenCordHandbookTests"
UITEST_DIR = "GreenCordHandbookUITests"

# Bundled alongside the app so the unit tests can compare the app's content
# against the pipeline's own artefacts.
TEST_RESOURCES = [
    "content/handbook-outline.md",
    "content/handbook.json",
    "content/requirements.json",
    "content/source/PISDGreenCordHandbook.pdf",
]

_used_ids = set()


def oid(*parts):
    """A stable 24-hex-character object id derived from what the object is."""
    seed = "|".join(str(p) for p in parts)
    digest = hashlib.sha256(seed.encode()).hexdigest().upper()
    candidate = digest[:24]
    salt = 0
    while candidate in _used_ids:
        salt += 1
        candidate = hashlib.sha256(f"{seed}#{salt}".encode()).hexdigest().upper()[:24]
    _used_ids.add(candidate)
    return candidate


def swift_sources(directory):
    """Every .swift file under a directory, relative to the project root."""
    found = []
    base = os.path.join(ROOT, directory)
    for current, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d != "Resources")
        for name in sorted(files):
            if name.endswith(".swift"):
                found.append(
                    os.path.relpath(os.path.join(current, name), ROOT)
                )
    return sorted(found)


def file_type(path):
    # An .xcassets must be declared as a folder.assetcatalog, or Xcode copies the
    # directory into the bundle verbatim instead of running actool over it. The
    # app then finds no Assets.car, every Color("BrandMaroon") silently falls
    # back, and there is no app icon.
    if path.endswith(".xcassets"):
        return "folder.assetcatalog"
    return {
        ".swift": "sourcecode.swift",
        ".json": "text.json",
        ".md": "net.daringfireball.markdown",
        ".pdf": "image.pdf",
        ".plist": "text.plist.xml",
        ".xcprivacy": "text.plist.xml",
        ".png": "image.png",
    }.get(os.path.splitext(path)[1], "text")


class Project:
    def __init__(self):
        self.objects = []
        self.file_refs = {}     # path -> id
        self.build_files = {}   # (path, target) -> id

    def add(self, text):
        self.objects.append(text)

    def file_ref(self, path, name=None):
        if path in self.file_refs:
            return self.file_refs[path]
        ref = oid("fileref", path)
        self.file_refs[path] = ref
        display = name or os.path.basename(path)
        self.add(
            f'\t\t{ref} /* {display} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = "{file_type(path)}"; '
            f'name = "{display}"; path = "{path}"; sourceTree = "<group>"; }};'
        )
        return ref

    def build_file(self, path, target, settings=""):
        key = (path, target)
        if key in self.build_files:
            return self.build_files[key]
        ref = self.file_ref(path)
        build = oid("buildfile", path, target)
        self.build_files[key] = build
        extra = f" settings = {{{settings}}};" if settings else ""
        self.add(
            f'\t\t{build} /* {os.path.basename(path)} in {target} */ = '
            f'{{isa = PBXBuildFile; fileRef = {ref} /* {os.path.basename(path)} */;{extra} }};'
        )
        return build

    def group(self, name, children, path=None, ident=None):
        ref = ident or oid("group", name, path or "")
        child_list = "\n".join(f"\t\t\t\t{c}," for c in children)
        path_line = f'\t\t\tpath = "{path}";\n' if path else ""
        self.add(
            f'\t\t{ref} /* {name} */ = {{\n'
            f'\t\t\tisa = PBXGroup;\n'
            f'\t\t\tchildren = (\n{child_list}\n\t\t\t);\n'
            f'{path_line}'
            f'\t\t\tname = "{name}";\n'
            f'\t\t\tsourceTree = "<group>";\n'
            f'\t\t}};'
        )
        return ref


def build_settings(common, extra):
    merged = dict(common)
    merged.update(extra)
    # A setting written with an empty value - DEVELOPMENT_TEAM when no team is
    # configured - makes the whole pbxproj unreadable to Xcode. Leave it out.
    return "\n".join(
        f"\t\t\t\t{key} = {value};"
        for key, value in sorted(merged.items())
        if value != ""
    )


def main():
    project = Project()

    app_sources = swift_sources(APP_DIR)
    test_sources = swift_sources(TEST_DIR)
    uitest_sources = swift_sources(UITEST_DIR)

    app_resources = [
        f"{APP_DIR}/Assets.xcassets",
        f"{APP_DIR}/PrivacyInfo.xcprivacy",
        f"{APP_DIR}/Resources/handbook.json",
        f"{APP_DIR}/Resources/requirements.json",
        f"{APP_DIR}/Resources/PISDGreenCordHandbook.pdf",
    ]
    for path in app_resources:
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            raise SystemExit(f"missing app resource: {path}")

    # ---- build phases ------------------------------------------------------

    app_source_files = [project.build_file(p, "app") for p in app_sources]
    app_resource_files = [project.build_file(p, "app") for p in app_resources]
    test_source_files = [project.build_file(p, "tests") for p in test_sources]
    test_resource_files = [project.build_file(p, "tests") for p in TEST_RESOURCES]
    uitest_source_files = [project.build_file(p, "uitests") for p in uitest_sources]

    def phase(kind, name, files, ident):
        listing = "\n".join(f"\t\t\t\t{f}," for f in files)
        project.add(
            f'\t\t{ident} /* {name} */ = {{\n'
            f'\t\t\tisa = {kind};\n'
            f'\t\t\tbuildActionMask = 2147483647;\n'
            f'\t\t\tfiles = (\n{listing}\n\t\t\t);\n'
            f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
            f'\t\t}};'
        )
        return ident

    app_sources_phase = phase(
        "PBXSourcesBuildPhase", "Sources", app_source_files, oid("phase", "app", "sources")
    )
    app_resources_phase = phase(
        "PBXResourcesBuildPhase", "Resources", app_resource_files,
        oid("phase", "app", "resources")
    )
    app_frameworks_phase = phase(
        "PBXFrameworksBuildPhase", "Frameworks", [], oid("phase", "app", "frameworks")
    )
    test_sources_phase = phase(
        "PBXSourcesBuildPhase", "Sources", test_source_files, oid("phase", "tests", "sources")
    )
    test_resources_phase = phase(
        "PBXResourcesBuildPhase", "Resources", test_resource_files,
        oid("phase", "tests", "resources")
    )
    test_frameworks_phase = phase(
        "PBXFrameworksBuildPhase", "Frameworks", [], oid("phase", "tests", "frameworks")
    )
    uitest_sources_phase = phase(
        "PBXSourcesBuildPhase", "Sources", uitest_source_files,
        oid("phase", "uitests", "sources")
    )
    uitest_frameworks_phase = phase(
        "PBXFrameworksBuildPhase", "Frameworks", [], oid("phase", "uitests", "frameworks")
    )

    # ---- groups ------------------------------------------------------------

    def nested_group(name, paths, prefix):
        """Mirror the directory layout so the navigator matches the disk."""
        by_dir = {}
        for path in paths:
            relative = os.path.relpath(path, prefix)
            directory = os.path.dirname(relative)
            by_dir.setdefault(directory, []).append(path)

        children = []
        for path in sorted(by_dir.get("", [])):
            children.append(project.file_ref(path))
        for directory in sorted(d for d in by_dir if d):
            refs = [project.file_ref(p) for p in sorted(by_dir[directory])]
            children.append(project.group(directory, refs))
        return project.group(name, children)

    app_group = nested_group(
        APP_DIR,
        app_sources + app_resources + [f"{APP_DIR}/Info.plist"],
        APP_DIR,
    )
    tests_group = nested_group(TEST_DIR, test_sources, TEST_DIR)
    uitests_group = nested_group(UITEST_DIR, uitest_sources, UITEST_DIR)
    content_group = project.group(
        "content", [project.file_ref(p) for p in TEST_RESOURCES]
    )

    app_product = oid("product", "app")
    test_product = oid("product", "tests")
    uitest_product = oid("product", "uitests")
    project.add(
        f'\t\t{app_product} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; '
        f'explicitFileType = wrapper.application; includeInIndex = 0; '
        f'path = "{PROJECT_NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    project.add(
        f'\t\t{test_product} /* {PROJECT_NAME}Tests.xctest */ = {{isa = PBXFileReference; '
        f'explicitFileType = wrapper.cfbundle; includeInIndex = 0; '
        f'path = "{PROJECT_NAME}Tests.xctest"; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    project.add(
        f'\t\t{uitest_product} /* {PROJECT_NAME}UITests.xctest */ = {{isa = PBXFileReference; '
        f'explicitFileType = wrapper.cfbundle; includeInIndex = 0; '
        f'path = "{PROJECT_NAME}UITests.xctest"; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    products_group = project.group(
        "Products", [app_product, test_product, uitest_product]
    )

    root_group = project.group(
        PROJECT_NAME,
        [app_group, tests_group, uitests_group, content_group, products_group],
        ident=oid("group", "root"),
    )

    # ---- targets -----------------------------------------------------------

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT_VERSION,
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    }
    debug_common = dict(
        common,
        **{
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
        },
    )
    release_common = dict(
        common,
        **{
            "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
            "ENABLE_NS_ASSERTIONS": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "VALIDATE_PRODUCT": "YES",
        },
    )

    app_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        # Signing is switched off for the simulator, so the build and test
        # gates run without anyone needing a developer account. A device build
        # signs normally, which is what makes it possible to run this on a real
        # phone: set GREENCORD_TEAM_ID and regenerate.
        '"CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]"': "NO",
        '"CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]"': "NO",
        "DEVELOPMENT_TEAM": TEAM_ID,
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "0.1.0",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f'"{APP_DIR}/Info.plist"',
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        # iPhone and iPad.
        "TARGETED_DEVICE_FAMILY": '"1,2"',
        "GREENCORD_BACKEND_URL": f'"{BACKEND_URL}"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    }
    test_settings = {
        "BUNDLE_LOADER": '"$(TEST_HOST)"',
        "TEST_HOST": f'"$(BUILT_PRODUCTS_DIR)/{PROJECT_NAME}.app/{PROJECT_NAME}"',
        '"CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]"': "NO",
        '"CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]"': "NO",
        "DEVELOPMENT_TEAM": TEAM_ID,
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.tests",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "TARGETED_DEVICE_FAMILY": '"1,2"',
        "LD_RUNPATH_SEARCH_PATHS": (
            '"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"'
        ),
    }
    uitest_settings = {
        '"CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]"': "NO",
        '"CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]"': "NO",
        "DEVELOPMENT_TEAM": TEAM_ID,
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.uitests",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "TEST_TARGET_NAME": f'"{PROJECT_NAME}"',
        "TARGETED_DEVICE_FAMILY": '"1,2"',
        "LD_RUNPATH_SEARCH_PATHS": (
            '"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"'
        ),
    }

    def config(name, settings, ident):
        project.add(
            f'\t\t{ident} /* {name} */ = {{\n'
            f'\t\t\tisa = XCBuildConfiguration;\n'
            f'\t\t\tbuildSettings = {{\n{settings}\n\t\t\t}};\n'
            f'\t\t\tname = {name};\n'
            f'\t\t}};'
        )
        return ident

    def config_list(owner, debug, release, ident):
        project.add(
            f'\t\t{ident} /* Build configuration list for {owner} */ = {{\n'
            f'\t\t\tisa = XCConfigurationList;\n'
            f'\t\t\tbuildConfigurations = (\n'
            f'\t\t\t\t{debug} /* Debug */,\n'
            f'\t\t\t\t{release} /* Release */,\n'
            f'\t\t\t);\n'
            f'\t\t\tdefaultConfigurationIsVisible = 0;\n'
            f'\t\t\tdefaultConfigurationName = Release;\n'
            f'\t\t}};'
        )
        return ident

    project_debug = config(
        "Debug", build_settings(debug_common, {}), oid("config", "project", "debug")
    )
    project_release = config(
        "Release", build_settings(release_common, {}), oid("config", "project", "release")
    )
    project_configs = config_list(
        "PBXProject", project_debug, project_release, oid("configlist", "project")
    )

    target_configs = {}
    for key, settings in (
        ("app", app_settings),
        ("tests", test_settings),
        ("uitests", uitest_settings),
    ):
        debug = config(
            "Debug", build_settings(debug_common, settings), oid("config", key, "debug")
        )
        release = config(
            "Release", build_settings(release_common, settings), oid("config", key, "release")
        )
        target_configs[key] = config_list(
            key, debug, release, oid("configlist", key)
        )

    app_target = oid("target", "app")
    test_target = oid("target", "tests")
    uitest_target = oid("target", "uitests")

    test_dependency = oid("dependency", "tests")
    uitest_dependency = oid("dependency", "uitests")
    test_proxy = oid("proxy", "tests")
    uitest_proxy = oid("proxy", "uitests")
    project_object = oid("project", "root")

    for proxy, dependency in ((test_proxy, test_dependency), (uitest_proxy, uitest_dependency)):
        project.add(
            f'\t\t{proxy} /* PBXContainerItemProxy */ = {{\n'
            f'\t\t\tisa = PBXContainerItemProxy;\n'
            f'\t\t\tcontainerPortal = {project_object};\n'
            f'\t\t\tproxyType = 1;\n'
            f'\t\t\tremoteGlobalIDString = {app_target};\n'
            f'\t\t\tremoteInfo = {PROJECT_NAME};\n'
            f'\t\t}};'
        )
        project.add(
            f'\t\t{dependency} /* PBXTargetDependency */ = {{\n'
            f'\t\t\tisa = PBXTargetDependency;\n'
            f'\t\t\ttarget = {app_target} /* {PROJECT_NAME} */;\n'
            f'\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n'
            f'\t\t}};'
        )

    def target(ident, name, product_type, product_ref, phases, configs, dependencies):
        phase_list = "\n".join(f"\t\t\t\t{p}," for p in phases)
        dependency_list = "\n".join(f"\t\t\t\t{d}," for d in dependencies)
        project.add(
            f'\t\t{ident} /* {name} */ = {{\n'
            f'\t\t\tisa = PBXNativeTarget;\n'
            f'\t\t\tbuildConfigurationList = {configs};\n'
            f'\t\t\tbuildPhases = (\n{phase_list}\n\t\t\t);\n'
            f'\t\t\tbuildRules = (\n\t\t\t);\n'
            f'\t\t\tdependencies = (\n{dependency_list}\n\t\t\t);\n'
            f'\t\t\tname = "{name}";\n'
            f'\t\t\tproductName = "{name}";\n'
            f'\t\t\tproductReference = {product_ref};\n'
            f'\t\t\tproductType = "{product_type}";\n'
            f'\t\t}};'
        )

    target(
        app_target, PROJECT_NAME, "com.apple.product-type.application", app_product,
        [app_sources_phase, app_frameworks_phase, app_resources_phase],
        target_configs["app"], [],
    )
    target(
        test_target, f"{PROJECT_NAME}Tests", "com.apple.product-type.bundle.unit-test",
        test_product,
        [test_sources_phase, test_frameworks_phase, test_resources_phase],
        target_configs["tests"], [test_dependency],
    )
    target(
        uitest_target, f"{PROJECT_NAME}UITests", "com.apple.product-type.bundle.ui-testing",
        uitest_product,
        [uitest_sources_phase, uitest_frameworks_phase],
        target_configs["uitests"], [uitest_dependency],
    )

    project.add(
        f'\t\t{project_object} /* Project object */ = {{\n'
        f'\t\t\tisa = PBXProject;\n'
        f'\t\t\tattributes = {{\n'
        f'\t\t\t\tBuildIndependentTargetsInParallel = 1;\n'
        f'\t\t\t\tLastSwiftUpdateCheck = 2600;\n'
        f'\t\t\t\tLastUpgradeCheck = 2600;\n'
        f'\t\t\t\tTargetAttributes = {{\n'
        f'\t\t\t\t\t{app_target} = {{CreatedOnToolsVersion = 26.0;}};\n'
        f'\t\t\t\t\t{test_target} = {{CreatedOnToolsVersion = 26.0; TestTargetID = {app_target};}};\n'
        f'\t\t\t\t\t{uitest_target} = {{CreatedOnToolsVersion = 26.0; TestTargetID = {app_target};}};\n'
        f'\t\t\t\t}};\n'
        f'\t\t\t}};\n'
        f'\t\t\tbuildConfigurationList = {project_configs};\n'
        f'\t\t\tdevelopmentRegion = en;\n'
        f'\t\t\thasScannedForEncodings = 0;\n'
        f'\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n'
        f'\t\t\tmainGroup = {root_group};\n'
        f'\t\t\tproductRefGroup = {products_group};\n'
        f'\t\t\tprojectDirPath = "";\n'
        f'\t\t\tprojectRoot = "";\n'
        f'\t\t\ttargets = (\n'
        f'\t\t\t\t{app_target},\n'
        f'\t\t\t\t{test_target},\n'
        f'\t\t\t\t{uitest_target},\n'
        f'\t\t\t);\n'
        f'\t\t}};'
    )

    body = "\n".join(project.objects)
    pbxproj = (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n\t};\n"
        "\tobjectVersion = 56;\n"
        f"\trootObject = {project_object} /* Project object */;\n"
        "\tobjects = {\n"
        f"{body}\n"
        "\t};\n"
        "}\n"
    )

    project_path = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")
    if os.path.exists(project_path):
        shutil.rmtree(project_path)
    os.makedirs(os.path.join(project_path, "project.xcworkspace", "xcshareddata"))
    os.makedirs(os.path.join(project_path, "xcshareddata", "xcschemes"))

    with open(os.path.join(project_path, "project.pbxproj"), "w") as fh:
        fh.write(pbxproj)

    with open(
        os.path.join(project_path, "project.xcworkspace", "contents.xcworkspacedata"), "w"
    ) as fh:
        fh.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace version = "1.0">\n'
            '   <FileRef location = "self:"></FileRef>\n'
            "</Workspace>\n"
        )
    with open(
        os.path.join(
            project_path, "project.xcworkspace", "xcshareddata", "WorkspaceSettings.xcsettings"
        ),
        "w",
    ) as fh:
        fh.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            "\t<key>BuildSystemType</key>\n\t<string>Latest</string>\n"
            "</dict>\n</plist>\n"
        )

    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "{PROJECT_NAME}.app"
               BlueprintName = "{PROJECT_NAME}"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <!-- shouldUseLaunchSchemeArgsEnv is NO so the tests do not inherit the Run
        action's backend URL. Tests must behave the same whether or not a
        server happens to be running on this machine. -->
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "NO">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "{PROJECT_NAME}Tests.xctest"
               BlueprintName = "{PROJECT_NAME}Tests"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uitest_target}"
               BuildableName = "{PROJECT_NAME}UITests.xctest"
               BlueprintName = "{PROJECT_NAME}UITests"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <!-- Points the app at the local prototype backend, so Run just works
           once the seed script is running with its server kept alive. Untick
           this in the scheme editor to run the app as a reader, with no
           server at all. A double hyphen is illegal inside an XML comment,
           so no command flags are spelled out here. -->
      <EnvironmentVariables>
         <EnvironmentVariable key = "GREENCORD_BACKEND_URL" value = "{BACKEND_URL}" isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{PROJECT_NAME}.app"
            BlueprintName = "{PROJECT_NAME}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{PROJECT_NAME}.app"
            BlueprintName = "{PROJECT_NAME}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
    with open(
        os.path.join(project_path, "xcshareddata", "xcschemes", f"{PROJECT_NAME}.xcscheme"), "w"
    ) as fh:
        fh.write(scheme)

    print(f"wrote {project_path}")
    print(f"  app sources      : {len(app_sources)}")
    print(f"  app resources    : {len(app_resources)}")
    print(f"  unit tests       : {len(test_sources)}")
    print(f"  ui tests         : {len(uitest_sources)}")
    print(f"  deployment target: iOS {DEPLOYMENT_TARGET}")
    print(f"  device family    : 1,2 (iPhone + iPad)")


if __name__ == "__main__":
    main()
