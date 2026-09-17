#include "MMDAnchorRecorderSettings.h"

UMMDAnchorRecorderSettings::UMMDAnchorRecorderSettings()
{
	CategoryName = TEXT("MMD");

	// 锚点表输出路径：默认为空，使用前请在 Project Settings → MMD 中指向你的
	// AIControl/anchors.csv（本仓库位于 Latest_Development/AI/AIControl/ 下）
	AnchorsCsvPath = TEXT("");
	bInvertLightDirection = true;
	// 相机固定正对角色正面 → 相机在物体 +Y 侧。与 collect_training_data.py 的
	// V_CAM、shader 的 (CameraOrigin - ObjectPosition) 同一约定。
	FallbackVCam = FVector(0.0, 1.0, 0.0);
}

FString UMMDAnchorRecorderSettings::GetAnchorsCsvPath()
{
	const UMMDAnchorRecorderSettings* Settings = GetDefault<UMMDAnchorRecorderSettings>();
	return Settings->AnchorsCsvPath;
}

bool UMMDAnchorRecorderSettings::ShouldInvertLightDirection()
{
	const UMMDAnchorRecorderSettings* Settings = GetDefault<UMMDAnchorRecorderSettings>();
	return Settings->bInvertLightDirection;
}

FVector UMMDAnchorRecorderSettings::GetFallbackVCam()
{
	const UMMDAnchorRecorderSettings* Settings = GetDefault<UMMDAnchorRecorderSettings>();
	FVector V = Settings->FallbackVCam;
	// normalize(0) 会产生 NaN 并一路污染到锚点表，退化为默认的 +Y。
	if (!V.Normalize())
	{
		V = FVector(0.0, 1.0, 0.0);
	}
	return V;
}
