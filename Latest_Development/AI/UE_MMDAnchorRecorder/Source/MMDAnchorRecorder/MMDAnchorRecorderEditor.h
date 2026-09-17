#pragma once

#include "CoreMinimal.h"

/**
 * MMD Anchor Recorder 核心抓取逻辑。
 *
 * ⚠ 特征约定（v6）：三个特征，四处必须严格一致 ——
 *     LdotV   = dot(L, V_cam)     光源相对相机的朝向（>0 顺光，<0 逆光）
 *     L_up    = L.Z               光源高度（>0 顶光，<0 底光）
 *     L_right = dot(L, Right)     光源在角色左右哪一侧，Right = cross(Z_up, V_cam)
 *   其中 V_cam = 物体中心 → 相机，是「每帧一个常量」，**不是**逐像素的
 *   CameraDirectionVector。四处为：
 *     · 本插件（RecordAnchor / ExportAnchorsFromSequence）
 *     · collect_training_data.py 的 V_CAM / RIGHT / features()
 *     · shader 端 GetWorldCameraOrigin - GetObjectWorldPosition 与 cross(Z, V_cam)
 *     · anchors.csv 的表头列序
 *   若任何一处改用逐像素 V，AI 参数会在屏幕上漂移，特征也无法确定光向。
 *
 *   为什么需要 L_right：相机固定正对角色正面时 V_cam ≈ 常量，LdotV 与 L_up 只能把
 *   光向确定到一个**圆**（切向分量大小可由 √(1-LdotV²-L_up²) 算出，但符号未知），
 *   于是「左前光」与「右前光」会映射到同一组特征、取到同一组参数，而这两者的正确
 *   打光本来就不同。加 L_right 后特征与光向一一对应。
 *
 *   叉积退化时的兜底也必须是同一个值（三处都用 +X）：相机与 Z_up 平行（垂直俯视/
 *   仰视）时 cross(Z_up, V_cam) 是零向量，兜底值不一致会让同一组光照在训练集与
 *   运行时映射到不同特征，且不会报任何错。
 *
 * 一键抓取流程（RecordAnchor）：
 *   1. 从当前编辑器视口取相机位置，V_cam = normalize(CameraLocation - ActorLocation)；
 *   2. 从场景第一个启用的 DirectionalLight 取光方向（指向光源 = -ActorForward，与
 *      SkyAtmosphereLightDirection 一致）；
 *   3. 计算 LdotV / L_up / L_right；
 *   4. 从选中物体的 MeshComponent 材质实例读取 ShadowSmooth / ShadowLocation / ExposureScale；
 *   5. 追加一行到 anchors.csv。
 *
 * 之后运行 AIControl/retrain_all.py 重新训练并同步 MLP 权重。
 *
 * 批量导出流程（ExportAnchorsFromSequence）：
 *   1. 读取当前打开的 Level Sequence；
 *   2. 从绑定 DirectionalLight 的 Transform 轨道读旋转关键帧；
 *   3. 解析 V_cam —— **整段只做一次**，三级降级：关卡里按绑定名找相机 Actor 的当前
 *      位置 → 相机 Translation 通道的最早关键帧 → 设置里的 V_cam 兜底。本管线相机不动，
 *      相机轨道常常有轨道却零关键帧，此时通道求值恒为 0，只有「找 Actor」这一级能用。
 *      实际解出的 V_cam 会进日志和通知，导出后必须核对；
 *   4. 从 Material Parameter Collection (MPC) 轨道读 ShadowSmooth / ShadowLocation /
 *      ExposureScale 三个标量参数的关键帧；
 *   5. 以「光 + MPC 关键帧的时间并集」作为锚点（相机自身的关键帧不参与取并集 ——
 *      静止机位不应改变锚点位置），逐点求值并覆盖生成 anchors.csv；
 *   6. 参考原点取「当前选中的 Actor」，所以导出前必须先选中承载 MMD 材质的角色。
 */
class FMMDAnchorRecorderEditor
{
public:
	static void RecordAnchor();
	static void ExportAnchorsFromSequence();
};