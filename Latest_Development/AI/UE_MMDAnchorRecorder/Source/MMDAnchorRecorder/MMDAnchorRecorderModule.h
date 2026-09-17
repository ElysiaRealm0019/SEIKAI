#pragma once

#include "CoreMinimal.h"
#include "Modules/ModuleInterface.h"

/**
 * MMD Anchor Recorder 编辑器模块。
 * 在 LevelEditor 主工具栏注册「Record MMD Anchor」按钮，
 * 一键抓取当前视角/光照与材质参数并追加为锚点。
 */
class FMMDAnchorRecorderModule : public IModuleInterface
{
public:
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;

	FName GetMenuOwner() const { return MenuOwnerName; }

private:
	void RegisterMenus();

	// UToolMenus 所需的 owner 标识
	FName MenuOwnerName = TEXT("MMDAnchorRecorder");
};
