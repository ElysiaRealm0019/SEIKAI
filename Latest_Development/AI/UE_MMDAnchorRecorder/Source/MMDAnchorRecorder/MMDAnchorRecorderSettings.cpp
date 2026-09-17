#include "MMDAnchorRecorderSettings.h"

UMMDAnchorRecorderSettings::UMMDAnchorRecorderSettings()
{
	CategoryName = TEXT("MMD");

	// 默认指向 AI 训练工程下的锚点表（按需在 Project Settings 中修改）
	AnchorsCsvPath = TEXT("F:/TA/SimpleHLSLCode/Latest_Development/AI/AIControl/anchors.csv");
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
