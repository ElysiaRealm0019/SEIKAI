#include "MMDAnchorRecorderModule.h"
#include "MMDAnchorRecorderEditor.h"
#include "ToolMenus.h"
#include "Framework/MultiBox/MultiBoxBuilder.h"
#include "Styling/AppStyle.h"

#define LOCTEXT_NAMESPACE "FMMDAnchorRecorderModule"

void FMMDAnchorRecorderModule::StartupModule()
{
	UToolMenus::RegisterStartupCallback(
		FSimpleMulticastDelegate::FDelegate::CreateRaw(this, &FMMDAnchorRecorderModule::RegisterMenus));
}

void FMMDAnchorRecorderModule::ShutdownModule()
{
	UToolMenus::UnRegisterStartupCallback(this);
	UToolMenus::UnregisterOwner(this);
}

void FMMDAnchorRecorderModule::RegisterMenus()
{
	UE_LOG(LogTemp, Display, TEXT("[MMDAnchorRecorder] RegisterMenus called"));

	FToolMenuOwnerScoped OwnerScoped(this);

	// 1) 工具栏：扩展主工具栏(部分 5.8 版本会把新 Section 收进溢出菜单 "<>")
	UToolMenu* ToolBar = UToolMenus::Get()->ExtendMenu("LevelEditor.LevelEditorToolBar");
	if (ToolBar)
	{
		FToolMenuSection& ToolBarSection = ToolBar->FindOrAddSection(
			"MMD",
			LOCTEXT("MMDSectionLabel", "MMD"));

		ToolBarSection.AddMenuEntry(
			"RecordMMDAnchor",
			LOCTEXT("RecordMMDAnchorLabel", "Record MMD Anchor"),
			LOCTEXT("RecordMMDAnchorTooltip",
				"抓取当前视口相机 + 场景太阳方向计算 LdotV/L_up，读取选中物体材质实例的 "
				"ShadowSmooth / ShadowLocation / ExposureScale，追加到 anchors.csv"),
			FSlateIcon(FAppStyle::GetAppStyleSetName(), "Icons.Plus"),
			FUIAction(FExecuteAction::CreateStatic(&FMMDAnchorRecorderEditor::RecordAnchor))
		);

		ToolBarSection.AddMenuEntry(
			"ExportMMDAnchorsFromSequence",
			LOCTEXT("ExportMMDAnchorsFromSequenceLabel", "Export Anchors from Level Sequence"),
			LOCTEXT("ExportMMDAnchorsFromSequenceTooltip",
				"读取当前打开的 Level Sequence：从 DirectionalLight 的 Transform 旋转轨道 "
				"与 MPC 的 ShadowSmooth / ShadowLocation / ExposureScale 标量轨道，以关键帧时间并集 "
				"为锚点逐点求值，覆盖生成 anchors.csv"),
			FSlateIcon(FAppStyle::GetAppStyleSetName(), "Icons.MovieScene"),
			FUIAction(FExecuteAction::CreateStatic(&FMMDAnchorRecorderEditor::ExportAnchorsFromSequence))
		);
	}
	else
	{
		UE_LOG(LogTemp, Warning, TEXT("[MMDAnchorRecorder] ExtendMenu(LevelEditor.LevelEditorToolBar) returned null"));
	}

	// 2) 主菜单:在 Window 菜单下挂一个显式子菜单作为 100% 可发现的入口
	UToolMenu* WindowMenu = UToolMenus::Get()->ExtendMenu("LevelEditor.MainMenu.Window");
	if (WindowMenu)
	{
		FToolMenuSection& WindowSection = WindowMenu->FindOrAddSection(
			"MMDSection",
			LOCTEXT("MMDWindowSectionLabel", "MMD Anchor Recorder"));

		WindowSection.AddSubMenu(
			"MMDSubMenu",
			LOCTEXT("MMDSubMenuLabel", "MMD Anchor Recorder"),
			LOCTEXT("MMDSubMenuTooltip", "MMD Toon Shader 自适应参数 - 锚点工具"),
			FNewToolMenuChoice(FNewToolMenuDelegate::CreateLambda([this](UToolMenu* InSubMenu)
			{
				FToolMenuOwnerScoped OwnerScopedInLambda(GetMenuOwner());
				FToolMenuSection& SubSection = InSubMenu->FindOrAddSection("MMD");
				SubSection.AddMenuEntry(
					"RecordMMDAnchor_Menu",
					LOCTEXT("RecordMMDAnchorLabel", "Record MMD Anchor"),
					LOCTEXT("RecordMMDAnchorTooltip_Menu",
						"抓取当前视口相机 + 场景太阳方向计算 LdotV/L_up，读取选中物体材质实例的 "
						"ShadowSmooth / ShadowLocation / ExposureScale，追加到 anchors.csv"),
					FSlateIcon(FAppStyle::GetAppStyleSetName(), "Icons.Plus"),
					FUIAction(FExecuteAction::CreateStatic(&FMMDAnchorRecorderEditor::RecordAnchor))
				);
				SubSection.AddMenuEntry(
					"ExportMMDAnchorsFromSequence_Menu",
					LOCTEXT("ExportMMDAnchorsFromSequenceLabel", "Export Anchors from Level Sequence"),
					LOCTEXT("ExportMMDAnchorsFromSequenceTooltip_Menu",
						"读取当前打开的 Level Sequence:从 DirectionalLight 的 Transform 旋转轨道 "
						"与 MPC 的 ShadowSmooth / ShadowLocation / ExposureScale 标量轨道,以关键帧时间并集 "
						"为锚点逐点求值,覆盖生成 anchors.csv"),
					FSlateIcon(FAppStyle::GetAppStyleSetName(), "Icons.MovieScene"),
					FUIAction(FExecuteAction::CreateStatic(&FMMDAnchorRecorderEditor::ExportAnchorsFromSequence))
				);
			}))
		);
	}
	else
	{
		UE_LOG(LogTemp, Warning, TEXT("[MMDAnchorRecorder] ExtendMenu(LevelEditor.MainMenu.Window) returned null"));
	}

	UE_LOG(LogTemp, Display, TEXT("[MMDAnchorRecorder] RegisterMenus finished"));
}

#undef LOCTEXT_NAMESPACE

IMPLEMENT_MODULE(FMMDAnchorRecorderModule, MMDAnchorRecorder)
