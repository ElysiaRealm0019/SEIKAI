#pragma once

#include "CoreMinimal.h"
#include "Engine/DeveloperSettings.h"
#include "MMDAnchorRecorderSettings.generated.h"

/**
 * MMD Anchor Recorder 插件设置。
 * 打开路径：Project Settings → Plugins → MMD Anchor Recorder。
 */
UCLASS(config = Editor, defaultconfig, meta = (DisplayName = "MMD Anchor Recorder"))
class UMMDAnchorRecorderSettings : public UDeveloperSettings
{
	GENERATED_BODY()

public:
	UMMDAnchorRecorderSettings();

	/** anchors.csv 绝对路径（多参考点锚点表） */
	UPROPERTY(config, EditAnywhere, Category = "MMD", DisplayName = "Anchors CSV 路径")
	FString AnchorsCsvPath;

	/**
	 * 光源方向取反开关。
	 * 平行光沿自身 Forward 发射光线；材质 LightDirection（SkyAtmosphereLightDirection）
	 * 是「指向光源」的方向，因此默认取反（true）。
	 */
	UPROPERTY(config, EditAnywhere, Category = "MMD", DisplayName = "光源方向取反")
	bool bInvertLightDirection;

	/**
	 * V_cam 兜底向量（物体中心 → 相机），单位向量。
	 *
	 * 仅在「绑定的相机 Actor 在关卡里找不到」且「相机的 Translation 通道一个关键帧
	 * 都没有」时使用 —— 那两种情况下导出器无从得知机位，与其写 0（会把整张锚点表
	 * 打进错误特征空间且不报错），不如用一个显式配置的常量。
	 *
	 * 默认 (0,1,0) = 相机位于物体 +Y 侧回望，与 collect_training_data.py 的
	 * V_CAM、shader 的 GetWorldCameraOrigin - GetObjectWorldPosition 同一约定。
	 * 导出时会把实际解出的 V_cam 打进日志和通知，务必核对。
	 */
	UPROPERTY(config, EditAnywhere, Category = "MMD", DisplayName = "V_cam 兜底（物体→相机）")
	FVector FallbackVCam;

	/** 获取当前配置的 anchors.csv 路径 */
	static FString GetAnchorsCsvPath();

	/** 获取当前配置的光源方向取反开关 */
	static bool ShouldInvertLightDirection();

	/** 获取 V_cam 兜底向量（已归一化；退化时返回 +Y） */
	static FVector GetFallbackVCam();
};
