using UnrealBuildTool;

public class MMDAnchorRecorder : ModuleRules
{
	public MMDAnchorRecorder(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
		});

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"UnrealEd",
			"LevelEditor",
			"Slate",
			"SlateCore",
			"ToolMenus",
			"DeveloperSettings",
			"EditorSubsystem",
			"InputCore",
			"LevelSequence",
			"LevelSequenceEditor",
			"MovieScene",
			"MovieSceneTracks",
		});
	}
}
