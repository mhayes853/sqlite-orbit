#!/usr/bin/env ruby

require "fileutils"
require "xcodeproj"

root = File.expand_path("..", __dir__)
examples = File.join(root, "Examples")
project_path = File.join(examples, "Examples.xcodeproj")
project = Xcodeproj::Project.new(project_path)

feature = project.new_target(:framework, "RemindersFeature", :ios, "17.0")
app = project.new_target(:application, "Reminders", :ios, "17.0")
tests = project.new_target(:unit_test_bundle, "RemindersTests", :ios, "17.0")
app.add_dependency(feature)
tests.add_dependency(feature)
app.frameworks_build_phase.add_file_reference(feature.product_reference)
tests.frameworks_build_phase.add_file_reference(feature.product_reference)

embed_frameworks = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_frameworks.name = "Embed Frameworks"
embed_frameworks.dst_subfolder_spec = "10"
app.build_phases << embed_frameworks
embedded_feature = embed_frameworks.add_file_reference(feature.product_reference)
embedded_feature.settings = {
  "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"]
}

feature.build_configurations.each do |configuration|
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "co.sqlite-orbit.RemindersFeature"
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  configuration.build_settings["SWIFT_VERSION"] = "6.0"
  configuration.build_settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  configuration.build_settings["CODE_SIGN_STYLE"] = "Automatic"
end

app.build_configurations.each do |configuration|
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "co.sqlite-orbit.Reminders"
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  configuration.build_settings["SWIFT_VERSION"] = "6.0"
  configuration.build_settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  configuration.build_settings["CODE_SIGN_STYLE"] = "Automatic"
end

tests.build_configurations.each do |configuration|
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "co.sqlite-orbit.RemindersTests"
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  configuration.build_settings["SWIFT_VERSION"] = "6.0"
  configuration.build_settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
end

reminders_group = project.main_group.new_group("Reminders", "Reminders")
Dir[File.join(examples, "Reminders", "*.swift")].sort.each do |path|
  reference = reminders_group.new_file(File.basename(path))
  feature.source_build_phase.add_file_reference(reference)
end

app_group = project.main_group.new_group("RemindersApp", "RemindersApp")
Dir[File.join(examples, "RemindersApp", "*.swift")].sort.each do |path|
  reference = app_group.new_file(File.basename(path))
  app.source_build_phase.add_file_reference(reference)
end

tests_group = project.main_group.new_group("RemindersTests", "RemindersTests")
Dir[File.join(examples, "RemindersTests", "*.swift")].sort.each do |path|
  reference = tests_group.new_file(File.basename(path))
  tests.source_build_phase.add_file_reference(reference)
end

package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = ".."
project.root_object.package_references << package

product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = "SQLiteOrbit"
feature.package_product_dependencies << product

build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product
feature.frameworks_build_phase.files << build_file

project.save

scheme_directory = File.join(project_path, "xcshareddata", "xcschemes")
FileUtils.mkdir_p(scheme_directory)
File.write(
  File.join(scheme_directory, "Reminders.xcscheme"),
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="2700" version="1.7">
      <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        <BuildActionEntries>
          <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{app.uuid}" BuildableName="Reminders.app" BlueprintName="Reminders" ReferencedContainer="container:Examples.xcodeproj"/>
          </BuildActionEntry>
          <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{tests.uuid}" BuildableName="RemindersTests.xctest" BlueprintName="RemindersTests" ReferencedContainer="container:Examples.xcodeproj"/>
          </BuildActionEntry>
        </BuildActionEntries>
      </BuildAction>
      <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
        <Testables>
          <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{tests.uuid}" BuildableName="RemindersTests.xctest" BlueprintName="RemindersTests" ReferencedContainer="container:Examples.xcodeproj"/>
          </TestableReference>
        </Testables>
      </TestAction>
      <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
        <BuildableProductRunnable runnableDebuggingMode="0">
          <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{app.uuid}" BuildableName="Reminders.app" BlueprintName="Reminders" ReferencedContainer="container:Examples.xcodeproj"/>
        </BuildableProductRunnable>
      </LaunchAction>
      <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
        <BuildableProductRunnable runnableDebuggingMode="0">
          <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{app.uuid}" BuildableName="Reminders.app" BlueprintName="Reminders" ReferencedContainer="container:Examples.xcodeproj"/>
        </BuildableProductRunnable>
      </ProfileAction>
      <AnalyzeAction buildConfiguration="Debug"/>
      <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
    </Scheme>
  XML
)
