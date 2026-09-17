#include "MMDAnchorRecorderEditor.h"
#include "MMDAnchorRecorderSettings.h"

#include "EngineUtils.h"
#include "Engine/DirectionalLight.h"
#include "Components/LightComponent.h"
#include "Components/MeshComponent.h"
#include "Materials/MaterialInstance.h"
#include "Materials/MaterialInterface.h"
#include "Editor.h"
#include "Subsystems/EditorActorSubsystem.h"
#include "Subsystems/UnrealEditorSubsystem.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Misc/FrameNumber.h"
#include "Misc/FrameTime.h"
#include "Misc/FrameRate.h"
#include "Framework/Notifications/NotificationManager.h"
#include "Widgets/Notifications/SNotificationList.h"

// Level Sequence / MovieScene
#include "LevelSequence.h"
#include "LevelSequenceEditorBlueprintLibrary.h"
#include "MovieScene.h"
#include "MovieSceneBinding.h"
#include "MovieScenePossessable.h"
#include "MovieSceneSpawnable.h"
#include "Channels/MovieSceneChannelProxy.h"
#include "Channels/MovieSceneChannelHandle.h"
#include "Channels/MovieSceneChannelEditorData.h"
#include "Channels/MovieSceneDoubleChannel.h"
#include "Channels/MovieSceneFloatChannel.h"
#include "Tracks/MovieScene3DTransformTrack.h"
#include "Tracks/MovieSceneEulerTransformTrack.h"
#include "Sections/MovieScene3DTransformSection.h"
#include "Tracks/MovieSceneMaterialParameterCollectionTrack.h"
#include "Sections/MovieSceneParameterSection.h"

namespace MMDAnchorRecorderPrivate
{
	/** 弹编辑器通知 */
	void Notify(const FString& Message, bool bSuccess)
	{
		FNotificationInfo Info(FText::FromString(Message));
		Info.ExpireDuration = 8.0f;
		Info.bUseThrobber = false;
		FSlateNotificationManager::Get().AddNotification(Info);

		if (bSuccess)
		{
			UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: %s"), *Message);
		}
		else
		{
			UE_LOG(LogTemp, Warning, TEXT("MMDAnchorRecorder: %s"), *Message);
		}
	}

	/** 取当前激活的透视视口相机 */
	bool GetActiveViewportCamera(FVector& OutLocation, FRotator& OutRotation)
	{
		if (!GEditor)
		{
			return false;
		}
		if (UUnrealEditorSubsystem* Subsystem = GEditor->GetEditorSubsystem<UUnrealEditorSubsystem>())
		{
			return Subsystem->GetLevelViewportCameraInfo(OutLocation, OutRotation);
		}
		return false;
	}

	/** 找场景中第一个启用的 DirectionalLight */
	ADirectionalLight* FindMainDirectionalLight(UWorld* World)
	{
		for (TActorIterator<ADirectionalLight> It(World); It; ++It)
		{
			ADirectionalLight* Light = *It;
			if (Light && Light->GetLightComponent() && Light->GetLightComponent()->IsVisible())
			{
				return Light;
			}
		}
		return nullptr;
	}

	/**
	 * anchors.csv 表头。列顺序必须与 collect_training_data.py 的
	 * FEATURE_NAMES + PARAM_NAMES 一致：特征列在前、参数列在后，
	 * 脚本按「第一个参数列的下标」切分特征/输出。
	 * 两处各写一份表头曾经漂移过，统一到这里。
	 *
	 * ⚠ note 必须恒为**最后一列**：MergeAnchorsCsv 靠「最后一个逗号之后」定位 note
	 *   来判定行归属（每个序列拥有自己的行）。往 note 后面加列会静默破坏这个判定 ——
	 *   所有行都会被当成「不属于任何序列」而永久累积，且不报任何错。
	 *   所以 V_cam 三列只能插在 note **之前**。
	 *
	 * VcamX/Y/Z 记录**生成该行时导出器实际用的 V_cam**（逐行落盘，不是全表一个）。
	 * 为什么必须逐行：V_cam 取决于参考原点，而原点取错这件事全程不报错 ——
	 * 训练指标一切正常，上机才发现特征空间全错。实测过一次：在 Sequencer 里调光的
	 * 关键帧时灯处于选中状态，导出器把位于世界原点的灯当成角色原点，25 个锚点
	 * 全部落进错误特征空间。文件里混了不同 V_cam 的批次时，只有逐行记录才分得出来。
	 */
	const TCHAR* kAnchorsHeader =
		TEXT("LdotV,L_up,L_right,ShadowSmooth,ShadowLocation,ExposureScale,")
		TEXT("VcamX,VcamY,VcamZ,note\n");

	/** 表头列数（含 note）。 */
	constexpr int32 kAnchorsNumCols = 10;

	/**
	 * 旧格式行（note 之前只有 6 个数据列）补齐空 V_cam 列。
	 * 空值语义是「这一行的 V_cam 未知」—— 故意留空而不猜，由 collect_training_data.py
	 * 拦下并报错。猜一个值正是这三列要根治的静默错配。已是新格式的行原样返回。
	 */
	FString PadLegacyAnchorRow(const FString& Line)
	{
		TArray<FString> Fields;
		Line.ParseIntoArray(Fields, TEXT(","), /*bCullEmpty=*/false);
		if (Fields.Num() >= kAnchorsNumCols || Fields.Num() == 0)
		{
			return Line;
		}
		// 最后一列是 note，在它之前插入缺失的空列。
		TArray<FString> Rebuilt;
		for (int32 i = 0; i < Fields.Num() - 1; ++i)
		{
			Rebuilt.Add(Fields[i]);
		}
		while (Rebuilt.Num() < kAnchorsNumCols - 1)
		{
			Rebuilt.Add(TEXT(""));
		}
		Rebuilt.Add(Fields.Last());
		return FString::Join(Rebuilt, TEXT(","));
	}

	/**
	 * 把既有 anchors.csv 内容升级到当前列格式：表头一律换成规范表头，旧数据行补空
	 * V_cam 列，**不删任何行**（锚点是实验数据，宁可留下肉眼可见的空列也不静默丢弃）。
	 * OutPaddedRows 回报补了多少行。
	 */
	FString NormalizeAnchorsContent(const FString& Existing, int32& OutPaddedRows)
	{
		OutPaddedRows = 0;
		TArray<FString> Lines;
		Existing.ParseIntoArrayLines(Lines, /*bCullEmpty=*/true);

		FString Content = kAnchorsHeader;
		for (int32 i = 0; i < Lines.Num(); ++i)
		{
			const FString& Line = Lines[i];
			// 第一行是表头（可能带 BOM，故用 Contains 而非 StartsWith），一律丢弃，
			// 改用规范表头 —— 沿用旧表头会让新行的 V_cam 三列与旧行整体错位。
			if (i == 0 && Line.Contains(TEXT("LdotV")))
			{
				continue;
			}
			if (Line.StartsWith(TEXT("#")))
			{
				continue;
			}
			const FString Row = PadLegacyAnchorRow(Line);
			if (Row.Len() != Line.Len())
			{
				++OutPaddedRows;
			}
			Content += Row;
			Content += TEXT("\n");
		}
		return Content;
	}

	/** 把一行追加到 CSV（文件不存在时先写表头；UTF-8 无 BOM） */
	bool AppendLineToCsv(const FString& FilePath, const FString& Line)
	{
		FString Existing;
		FFileHelper::LoadFileToString(Existing, *FilePath);

		if (!FPaths::FileExists(FilePath))
		{
			Existing = kAnchorsHeader;
		}
		else
		{
			int32 PaddedRows = 0;
			Existing = NormalizeAnchorsContent(Existing, PaddedRows);
			if (PaddedRows > 0)
			{
				UE_LOG(LogTemp, Warning,
					TEXT("MMDAnchorRecorder: anchors.csv 有 %d 行是旧格式（无 V_cam 列），"
						 "已补空列保留。这些行的 V_cam 未知，训练前必须重新导出。"),
					PaddedRows);
			}
		}

		Existing += Line;
		Existing += TEXT("\n");

		return FFileHelper::SaveStringToFile(Existing, *FilePath,
			FFileHelper::EEncodingOptions::ForceUTF8);
	}

	/**
	 * 合并写 anchors.csv：保留文件里**其它序列**的既有行，只替换本序列名下的旧行，
	 * 再追加本次导出的新行。
	 *
	 * 为什么不是纯覆盖写：
	 *   本项目的采集约定是「每个光照角度 = 一个独立的 Level Sequence」。逐序列导出
	 *   必须能累积成多圈锚点表（赤道圈 + 顶光圈 + 底光圈…）；覆盖写会把上一圈整个
	 *   丢掉，且不报任何错 —— 导出第二个角度时第一个角度的锚点静静消失。
	 * 为什么也不是纯追加：
	 *   锚点参数是审美初值，需按实际渲染效果反复微调，同一个序列会导出很多遍。
	 *   纯追加会在每次微调后留下重复的旧行，而且旧行不会被新行覆盖，只能手工清理。
	 *
	 * 归属判定：note 列的 "<序列名> " 前缀 —— 语义是「每个序列拥有自己的行」。
	 *
	 * ⚠ 历史遗留：早期 note 写的是硬编码版本标记（"seqV6 frame=.." / "seqV5 ..." /
	 *   "seq ..."），那些行只有在序列名**恰好等于**该标记时才会被认作本序列而替换。
	 *   不匹配的一律原样保留 —— 宁可留下肉眼可见的重复行，也不静默删掉实验数据。
	 *   OutReplacedRows / OutKeptRows 会回报实际替换与保留的行数，导出后据此核对。
	 */
	bool MergeAnchorsCsv(const FString& FilePath, const FString& SequenceName,
		const TArray<FString>& BodyLines, int32& OutReplacedRows, int32& OutKeptRows)
	{
		const FString OwnPrefix = SequenceName + TEXT(" ");

		TArray<FString> KeptLines;
		OutReplacedRows = 0;
		OutKeptRows = 0;

		FString Existing;
		if (FPaths::FileExists(FilePath) &&
			FFileHelper::LoadFileToString(Existing, *FilePath))
		{
			// 先把整份内容升级到当前列格式（规范表头 + 旧行补空 V_cam 列）。
			// 必须在判定行归属**之前**做：旧行补完列后 note 仍是最后一列，
			// 下面按「最后一个逗号之后」定位 note 的逻辑才继续成立。
			int32 PaddedRows = 0;
			Existing = NormalizeAnchorsContent(Existing, PaddedRows);
			if (PaddedRows > 0)
			{
				UE_LOG(LogTemp, Warning,
					TEXT("MMDAnchorRecorder: anchors.csv 有 %d 行是旧格式（无 V_cam 列），"
						 "已补空列保留。这些行的 V_cam 未知，训练前必须重新导出。"),
					PaddedRows);
			}

			TArray<FString> Lines;
			Existing.ParseIntoArrayLines(Lines, /*bCullEmpty=*/true);
			for (int32 i = 0; i < Lines.Num(); ++i)
			{
				const FString& Line = Lines[i];
				if (i == 0 && Line.Contains(TEXT("LdotV")))
				{
					continue;   // 表头由 NormalizeAnchorsContent 统一给出
				}
				// note 是最后一个逗号之后的部分（note 自身不含逗号）
				int32 CommaIdx = INDEX_NONE;
				if (Line.FindLastChar(TEXT(','), CommaIdx) &&
					CommaIdx + 1 < Line.Len() &&
					Line.Mid(CommaIdx + 1).StartsWith(OwnPrefix))
				{
					++OutReplacedRows;   // 本序列的旧行 → 丢弃，由新行替换
					continue;
				}
				KeptLines.Add(Line);
				++OutKeptRows;
			}
		}

		FString Content = kAnchorsHeader;
		for (const FString& Line : KeptLines)
		{
			Content += Line;
			Content += TEXT("\n");
		}
		for (const FString& Line : BodyLines)
		{
			Content += Line;
			Content += TEXT("\n");
		}
		return FFileHelper::SaveStringToFile(Content, *FilePath,
			FFileHelper::EEncodingOptions::ForceUTF8);
	}

	// -----------------------------------------------------------------------
	// MMD 材质识别 —— 两条导出路径共用的判据
	// -----------------------------------------------------------------------

	/** 一个暴露了 MMD 三个标量参数的材质槽位 */
	struct FMMDMaterialSlot
	{
		UMeshComponent*    MeshComp       = nullptr;
		int32              Slot           = INDEX_NONE;
		UMaterialInstance* Material       = nullptr;
		float              ShadowSmooth   = 1.0f;
		float              ShadowLocation = 0.0f;
		float              ExposureScale  = 1.0f;

		FString Describe() const
		{
			return FString::Printf(TEXT("%s[slot %d] = %s"),
				MeshComp ? *MeshComp->GetName() : TEXT("?"), Slot,
				Material ? *Material->GetName() : TEXT("?"));
		}
	};

	/**
	 * 收集 Actor 上所有暴露了 ShadowSmooth / ShadowLocation / ExposureScale
	 * 三个标量参数的材质槽位 —— 即「承载 MMD 材质的网格」。
	 *
	 * 这个判据被两处共用，且**必须**共用：
	 *   1) RecordAnchor()               —— 确定要读取哪三个参数值；
	 *   2) ExportAnchorsFromSequence()  —— 确定 V_cam 的参考原点该用哪个 Actor。
	 *
	 * 第 2) 处曾经只取 Selected[0]、不校验，实际踩过：在 Sequencer 里调光的关键帧时
	 * 灯处于选中状态，导出器就把位于世界原点的灯当成了角色原点，V_cam 偏 36.9°，
	 * 整张锚点表被静默打进错误的特征空间 —— 训练指标一切正常，上机全错。
	 */
	void CollectMMDMaterialSlots(AActor* Actor, TArray<FMMDMaterialSlot>& OutSlots)
	{
		if (!Actor)
		{
			return;
		}
		TArray<UMeshComponent*> MeshComps;
		Actor->GetComponents<UMeshComponent>(MeshComps);
		for (UMeshComponent* MeshComp : MeshComps)
		{
			if (!MeshComp)
			{
				continue;
			}
			const int32 NumMaterials = MeshComp->GetNumMaterials();
			for (int32 Slot = 0; Slot < NumMaterials; ++Slot)
			{
				UMaterialInstance* MaterialInstance =
					Cast<UMaterialInstance>(MeshComp->GetMaterial(Slot));
				if (!MaterialInstance)
				{
					continue;
				}
				float S, L, E;
				if (!MaterialInstance->GetScalarParameterValue(TEXT("ShadowSmooth"), S) ||
					!MaterialInstance->GetScalarParameterValue(TEXT("ShadowLocation"), L) ||
					!MaterialInstance->GetScalarParameterValue(TEXT("ExposureScale"), E))
				{
					continue;
				}
				FMMDMaterialSlot& New = OutSlots.AddDefaulted_GetRef();
				New.MeshComp       = MeshComp;
				New.Slot           = Slot;
				New.Material       = MaterialInstance;
				New.ShadowSmooth   = S;
				New.ShadowLocation = L;
				New.ExposureScale  = E;
			}
		}
	}

	/**
	 * 从当前关卡选中项里筛出承载 MMD 材质的 Actor。
	 *   OutCandidates —— 合格的参考原点候选；
	 *   OutNonMMDNames —— 被排除者的名字，供报错信息使用。
	 */
	void CollectSelectedMMDActors(TArray<AActor*>& OutCandidates, TArray<FString>& OutNonMMDNames)
	{
		OutCandidates.Reset();
		OutNonMMDNames.Reset();
		if (!GEditor)
		{
			return;
		}
		UEditorActorSubsystem* ActorSubsystem = GEditor->GetEditorSubsystem<UEditorActorSubsystem>();
		if (!ActorSubsystem)
		{
			return;
		}
		for (AActor* Candidate : ActorSubsystem->GetSelectedLevelActors())
		{
			if (!Candidate)
			{
				continue;
			}
			TArray<FMMDMaterialSlot> CandidateSlots;
			CollectMMDMaterialSlots(Candidate, CandidateSlots);
			if (CandidateSlots.Num() > 0)
			{
				OutCandidates.Add(Candidate);
			}
			else
			{
				OutNonMMDNames.Add(Candidate->GetName());
			}
		}
	}

	/** 把「参考原点无法唯一确定」的原因拼成人话，两个入口共用。 */
	FString DescribeOriginSelectionFailure(const TArray<AActor*>& Candidates,
		const TArray<FString>& NonMMDNames)
	{
		if (Candidates.Num() == 0 && NonMMDNames.Num() == 0)
		{
			return TEXT("当前没有选中任何 Actor。");
		}
		if (Candidates.Num() == 0)
		{
			return FString::Printf(TEXT("选中的 %d 个 Actor 都不承载 MMD 材质：%s"),
				NonMMDNames.Num(), *FString::Join(NonMMDNames, TEXT(", ")));
		}
		TArray<FString> CandidateNames;
		for (AActor* Candidate : Candidates)
		{
			CandidateNames.Add(Candidate ? Candidate->GetName() : TEXT("?"));
		}
		return FString::Printf(
			TEXT("选中的 Actor 里有 %d 个承载 MMD 材质：%s，无法确定哪个是参考原点"),
			Candidates.Num(), *FString::Join(CandidateNames, TEXT(", ")));
	}

	// -----------------------------------------------------------------------
	// 从 Level Sequence 批量导出的辅助函数
	// -----------------------------------------------------------------------

	/** 求值 double 通道在指定帧的值 */
	double EvalDouble(FMovieSceneDoubleChannel* Channel, FFrameNumber Time)
	{
		double Out = 0.0;
		if (Channel)
		{
			Channel->Evaluate(FFrameTime(Time), Out);
		}
		return Out;
	}

	/** 求值 float 通道在指定帧的值 */
	float EvalFloat(FMovieSceneFloatChannel* Channel, FFrameNumber Time)
	{
		float Out = 0.0f;
		if (Channel)
		{
			Channel->Evaluate(FFrameTime(Time), Out);
		}
		return Out;
	}

	/** 收集 double 通道的所有关键帧时间 */
	void CollectTimes(FMovieSceneDoubleChannel* Channel, TSet<FFrameNumber>& OutTimes)
	{
		if (!Channel)
		{
			return;
		}
		for (const FFrameNumber& Time : Channel->GetData().GetTimes())
		{
			OutTimes.Add(Time);
		}
	}

	/** 收集 float 通道的所有关键帧时间 */
	void CollectTimes(FMovieSceneFloatChannel* Channel, TSet<FFrameNumber>& OutTimes)
	{
		if (!Channel)
		{
			return;
		}
		for (const FFrameNumber& Time : Channel->GetData().GetTimes())
		{
			OutTimes.Add(Time);
		}
	}

	/** 判断轨道是否为 Transform 轨道（3D Transform 或 Euler Transform） */
	bool IsTransformTrack(UMovieSceneTrack* Track);

	/** 通过 guid 从 Possessable/Spawnable 取绑定显示名（FMovieSceneBinding::GetName 已弃用且返回空） */
	FString GetBindingName(UMovieScene* MovieScene, const FGuid& Guid)
	{
		const int32 NumPossessables = MovieScene->GetPossessableCount();
		for (int32 i = 0; i < NumPossessables; ++i)
		{
			const FMovieScenePossessable& P = MovieScene->GetPossessable(i);
			if (P.GetGuid() == Guid)
			{
				return P.GetName();
			}
		}
		const int32 NumSpawnables = MovieScene->GetSpawnableCount();
		for (int32 i = 0; i < NumSpawnables; ++i)
		{
			const FMovieSceneSpawnable& S = MovieScene->GetSpawnable(i);
			if (S.GetGuid() == Guid)
			{
				return S.GetName();
			}
		}
		return FString();
	}

	/** 打印一个 binding 下所有轨道的类名，用于诊断 */
	void LogBindingTracks(UMovieScene* MovieScene, const FString& Prefix, const FMovieSceneBinding& Binding)
	{
		FString TrackNames;
		for (UMovieSceneTrack* Track : Binding.GetTracks())
		{
			if (Track)
			{
				TrackNames += Track->GetClass()->GetName();
				TrackNames += TEXT(" ");
			}
		}
		UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: %s binding='%s' guid=%s tracks=[%s]"),
			*Prefix, *GetBindingName(MovieScene, Binding.GetObjectGuid()), *Binding.GetObjectGuid().ToString(), *TrackNames);
	}

	/** 找到绑定到光（DirectionalLight/Sun）的 binding guid，找不到时退化为第一个带 Transform 轨道的 binding */
	FGuid FindLightBindingGuid(UMovieScene* MovieScene)
	{
		auto MatchesLightName = [](const FString& Name) -> bool
		{
			return Name.Contains(TEXT("DirectionalLight")) ||
				Name.Contains(TEXT("Sun")) ||
				Name.Contains(TEXT("SkyLight")) ||
				Name.Contains(TEXT("Light"));
		};

		UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: 开始扫描 Level Sequence 所有 binding..."));

		// 先打印全部 binding，便于诊断
		for (const FMovieSceneBinding& Binding : const_cast<const UMovieScene*>(MovieScene)->GetBindings())
		{
			LogBindingTracks(MovieScene, TEXT("  "), Binding);
		}

		// 优先：名字像 Light 且带 Transform 轨道的 binding
		for (const FMovieSceneBinding& Binding : const_cast<const UMovieScene*>(MovieScene)->GetBindings())
		{
			const FString Name = GetBindingName(MovieScene, Binding.GetObjectGuid());
			if (!MatchesLightName(Name))
			{
				continue;
			}
			for (UMovieSceneTrack* Track : Binding.GetTracks())
			{
				if (IsTransformTrack(Track))
				{
					UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: 选中光 binding='%s'（名字匹配且有 Transform）"), *Name);
					return Binding.GetObjectGuid();
				}
			}
		}

		// 次优：第一个名字像 Light 的 binding（即使只有 Light 属性轨道）
		for (const FMovieSceneBinding& Binding : const_cast<const UMovieScene*>(MovieScene)->GetBindings())
		{
			const FString Name = GetBindingName(MovieScene, Binding.GetObjectGuid());
			if (MatchesLightName(Name))
			{
				UE_LOG(LogTemp, Warning, TEXT("MMDAnchorRecorder: 找到名字像光的 binding='%s'，但它没有 Transform 轨道"), *Name);
			}
		}

		// 退化：第一个含 Transform 轨道的 binding
		for (const FMovieSceneBinding& Binding : const_cast<const UMovieScene*>(MovieScene)->GetBindings())
		{
			for (UMovieSceneTrack* Track : Binding.GetTracks())
			{
				if (IsTransformTrack(Track))
				{
					const FString Name = GetBindingName(MovieScene, Binding.GetObjectGuid());
					UE_LOG(LogTemp, Warning, TEXT("MMDAnchorRecorder: 未找到光 binding，退化为第一个含 Transform 的 binding='%s'"), *Name);
					return Binding.GetObjectGuid();
				}
			}
		}
		return FGuid();
	}

	/** 找绑定到相机的 binding guid（CameraActor / CineCameraActor） */
	FGuid FindCameraBindingGuid(UMovieScene* MovieScene)
	{
		auto MatchesCameraName = [](const FString& Name) -> bool
		{
			return Name.Contains(TEXT("Camera")) || Name.Contains(TEXT("CineCam"));
		};

		for (const FMovieSceneBinding& Binding : const_cast<const UMovieScene*>(MovieScene)->GetBindings())
		{
			const FString Name = GetBindingName(MovieScene, Binding.GetObjectGuid());
			if (!MatchesCameraName(Name))
			{
				continue;
			}
			for (UMovieSceneTrack* Track : Binding.GetTracks())
			{
				if (IsTransformTrack(Track))
				{
					UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: 选中相机 binding='%s'"), *Name);
					return Binding.GetObjectGuid();
				}
			}
		}
		return FGuid();
	}

	/** 判断轨道是否为 Transform 轨道（3D Transform 或 Euler Transform） */
	bool IsTransformTrack(UMovieSceneTrack* Track)
	{
		return Cast<UMovieScene3DTransformTrack>(Track) != nullptr
			|| Cast<UMovieSceneEulerTransformTrack>(Track) != nullptr;
	}

	/**
	 * 按绑定名在关卡里找对应的 Actor。
	 *
	 * 静止机位常常「有 Transform 轨道、但一个关键帧都没有」—— 这是本管线的常态：
	 * 相机不动、光源动，相机轨道只是个占位。此时 Translation 通道求值恒为 0，
	 * 唯一可靠的位置来源是关卡里那个 Actor 本身，所以必须能按名字把它找回来。
	 *
	 * 匹配逐级放宽：完全相同 → 忽略大小写 → 前缀（UE 会给重名 Actor 加 _1/_2 后缀）。
	 * 每级都要求唯一命中，多个候选时放弃 —— 认错相机比认不出相机更糟，
	 * 前者会静默地把整张锚点表打进错误的特征空间。
	 */
	AActor* FindActorByBindingName(UWorld* World, const FString& BindingName)
	{
		if (!World || BindingName.IsEmpty())
		{
			return nullptr;
		}

		AActor* PrefixMatch = nullptr;
		int32 PrefixMatchCount = 0;

		for (TActorIterator<AActor> It(World); It; ++It)
		{
			AActor* Actor = *It;
			if (!Actor)
			{
				continue;
			}

			// GetActorNameOrLabel 在编辑器里返回 Outliner 显示名，通常正是绑定名
			const FString Label = Actor->GetActorNameOrLabel();
			const FString Name = Actor->GetName();

			if (Label == BindingName || Name == BindingName)
			{
				UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: 相机 Actor 精确匹配 '%s'"), *Name);
				return Actor;
			}
			if (Label.Equals(BindingName, ESearchCase::IgnoreCase) ||
				Name.Equals(BindingName, ESearchCase::IgnoreCase))
			{
				UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: 相机 Actor 忽略大小写匹配 '%s'"), *Name);
				return Actor;
			}
			if (Name.StartsWith(BindingName, ESearchCase::IgnoreCase) ||
				Label.StartsWith(BindingName, ESearchCase::IgnoreCase))
			{
				++PrefixMatchCount;
				PrefixMatch = Actor;
			}
		}

		if (PrefixMatchCount == 1)
		{
			UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: 相机 Actor 前缀匹配 '%s'"),
				*PrefixMatch->GetName());
			return PrefixMatch;
		}
		if (PrefixMatchCount > 1)
		{
			UE_LOG(LogTemp, Warning,
				TEXT("MMDAnchorRecorder: 绑定名 '%s' 前缀匹配到 %d 个 Actor，无法确定机位，放弃匹配"),
				*BindingName, PrefixMatchCount);
		}
		return nullptr;
	}

	/**
	 * 取 binding 的 Transform 三通道，Output 顺序恒为 [X, Y, Z]。
	 *   AxisPrefix = TEXT("Rotation")     旋转 X/Y/Z（对光即 Roll/Pitch/Yaw）
	 *   AxisPrefix = TEXT("Translation")  位置 X/Y/Z（对相机即世界位置）
	 */
	bool GetTransformChannels(UMovieScene* MovieScene, const FGuid& BindingGuid,
		const TCHAR* AxisPrefix, FMovieSceneDoubleChannel* OutChannels[3])
	{
		OutChannels[0] = OutChannels[1] = OutChannels[2] = nullptr;

		FMovieSceneBinding* Binding = MovieScene->FindBinding(BindingGuid);
		if (!Binding)
		{
			UE_LOG(LogTemp, Warning, TEXT("MMDAnchorRecorder: GetTransformChannels('%s') 找不到 binding %s"),
				AxisPrefix, *BindingGuid.ToString());
			return false;
		}

		UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: 检查光 binding '%s'，轨道数=%d"), *GetBindingName(MovieScene, BindingGuid), Binding->GetTracks().Num());

		for (UMovieSceneTrack* Track : Binding->GetTracks())
		{
			UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder:   轨道类名=%s"), Track ? *Track->GetClass()->GetName() : TEXT("null"));

			if (!IsTransformTrack(Track))
			{
				continue;
			}

			for (UMovieSceneSection* Section : Track->GetAllSections())
			{
				UMovieScene3DTransformSection* XformSection = Cast<UMovieScene3DTransformSection>(Section);
				if (!XformSection)
				{
					UE_LOG(LogTemp, Warning, TEXT("MMDAnchorRecorder:   Section 不是 UMovieScene3DTransformSection，实际=%s"),
						Section ? *Section->GetClass()->GetName() : TEXT("null"));
					continue;
				}

				// Transform section 的通道在 CacheChannelProxy() 里按 TransformMask 动态注册，
				// 只 Key 旋转时 GetChannels<T>() 返回的通道数量和顺序都不固定（可能是 3 或 9）。
				// 因此这里按通道名精确查找 Rotation.X/Y/Z，与引擎内部 GetKeyStruct 的做法一致。
				FMovieSceneChannelProxy& ChannelProxy = XformSection->GetChannelProxy();

				// 先打印所有通道名，便于诊断
				TArrayView<const FMovieSceneChannelEntry> Entries = ChannelProxy.GetAllEntries();
				for (const FMovieSceneChannelEntry& Entry : Entries)
				{
					TArrayView<FMovieSceneChannel* const> Channels = Entry.GetChannels();
					TArrayView<const FMovieSceneChannelMetaData> MetaData = Entry.GetMetaData();
					for (int32 i = 0; i < Channels.Num(); ++i)
					{
						const FName ChannelName = MetaData.IsValidIndex(i) ? MetaData[i].Name : FName();
						UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder:     通道名=%s 类型=%s"),
							*ChannelName.ToString(), *Entry.GetChannelTypeName().ToString());
					}
				}

				const FName ChannelNames[3] = {
					FName(*FString::Printf(TEXT("%s.X"), AxisPrefix)),
					FName(*FString::Printf(TEXT("%s.Y"), AxisPrefix)),
					FName(*FString::Printf(TEXT("%s.Z"), AxisPrefix)),
				};
				const FMovieSceneChannelHandle Handles[3] = {
					ChannelProxy.GetChannelByName<FMovieSceneDoubleChannel>(ChannelNames[0]),
					ChannelProxy.GetChannelByName<FMovieSceneDoubleChannel>(ChannelNames[1]),
					ChannelProxy.GetChannelByName<FMovieSceneDoubleChannel>(ChannelNames[2]),
				};

				OutChannels[0] = Handles[0].Get() ? static_cast<FMovieSceneDoubleChannel*>(Handles[0].Get()) : nullptr;
				OutChannels[1] = Handles[1].Get() ? static_cast<FMovieSceneDoubleChannel*>(Handles[1].Get()) : nullptr;
				OutChannels[2] = Handles[2].Get() ? static_cast<FMovieSceneDoubleChannel*>(Handles[2].Get()) : nullptr;

				UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder:   %s.X=%p Y=%p Z=%p"),
					AxisPrefix, OutChannels[0], OutChannels[1], OutChannels[2]);

				return OutChannels[0] && OutChannels[1] && OutChannels[2];
			}
		}
		return false;
	}

	/** 取 MPC 轨道里三个目标标量参数通道，Output 顺序 [ShadowSmooth, ShadowLocation, ExposureScale] */
	bool GetMpcScalarChannels(UMovieScene* MovieScene, FMovieSceneFloatChannel* OutChannels[3])
	{
		UMovieSceneMaterialParameterCollectionTrack* MpcTrack = nullptr;

		// 先在根轨道里找（MPC 轨道通常挂在根级）
		for (UMovieSceneTrack* Track : MovieScene->GetTracks())
		{
			MpcTrack = Cast<UMovieSceneMaterialParameterCollectionTrack>(Track);
			if (MpcTrack)
			{
				break;
			}
		}

		// 兜底：遍历所有 binding 的轨道
		if (!MpcTrack)
		{
			for (const FMovieSceneBinding& Binding : const_cast<const UMovieScene*>(MovieScene)->GetBindings())
			{
				for (UMovieSceneTrack* Track : Binding.GetTracks())
				{
					MpcTrack = Cast<UMovieSceneMaterialParameterCollectionTrack>(Track);
					if (MpcTrack)
					{
						break;
					}
				}
				if (MpcTrack)
				{
					break;
				}
			}
		}

		if (!MpcTrack)
		{
			return false;
		}

		FMovieSceneFloatChannel* Found[3] = { nullptr, nullptr, nullptr };
		for (UMovieSceneSection* Section : MpcTrack->GetAllSections())
		{
			UMovieSceneParameterSection* ParamSection =
				Cast<UMovieSceneParameterSection>(Section);
			if (!ParamSection)
			{
				continue;
			}
			for (FScalarParameterNameAndCurve& Scalar : ParamSection->GetScalarParameterNamesAndCurves())
			{
				const FName Name = Scalar.ParameterName;
				if (Name == FName(TEXT("ShadowSmooth")))
				{
					Found[0] = &Scalar.ParameterCurve;
				}
				else if (Name == FName(TEXT("ShadowLocation")))
				{
					Found[1] = &Scalar.ParameterCurve;
				}
				else if (Name == FName(TEXT("ExposureScale")))
				{
					Found[2] = &Scalar.ParameterCurve;
				}
			}
		}

		OutChannels[0] = Found[0];
		OutChannels[1] = Found[1];
		OutChannels[2] = Found[2];
		return Found[0] && Found[1] && Found[2];
	}
}

void FMMDAnchorRecorderEditor::RecordAnchor()
{
	using namespace MMDAnchorRecorderPrivate;

	if (!GEditor)
	{
		Notify(TEXT("GEditor 无效"), false);
		return;
	}

	UWorld* World = GEditor->GetEditorWorldContext().World();
	if (!World)
	{
		Notify(TEXT("未找到编辑器世界"), false);
		return;
	}

	// 1. 当前视口相机
	FVector CameraLocation;
	FRotator CameraRotation;
	if (!GetActiveViewportCamera(CameraLocation, CameraRotation))
	{
		Notify(TEXT("未找到透视视口相机"), false);
		return;
	}

	// 2. 选中物体（作为参考点，决定 V 的方向）
	//    判据与「从 Sequence 导出」路径**完全一致**：必须是承载 MMD 材质的 Actor，
	//    且恰好一个。理由见 CollectMMDMaterialSlots 的注释 —— 参考原点取错会让锚点
	//    静默落进错误的特征空间，训练指标看不出任何异常。
	TArray<AActor*> OriginCandidates;
	TArray<FString>  NonMMDNames;
	CollectSelectedMMDActors(OriginCandidates, NonMMDNames);
	if (OriginCandidates.Num() != 1)
	{
		Notify(FString::Printf(
			TEXT("记录中止：%s\n\n"
				"V_cam 的参考原点必须是承载 MMD 材质的角色 Actor（需暴露 ShadowSmooth /\n"
				"ShadowLocation / ExposureScale 三个参数）。\n"
				"请只选中角色 Actor 后重试。"),
			*DescribeOriginSelectionFailure(OriginCandidates, NonMMDNames)), false);
		return;
	}
	AActor* TargetActor = OriginCandidates[0];

	// 3. 主平行光（联动场景太阳）
	ADirectionalLight* DirectionalLight = FindMainDirectionalLight(World);
	if (!DirectionalLight)
	{
		Notify(TEXT("场景中没有启用的 DirectionalLight"), false);
		return;
	}

	// 光方向：与材质 LightDirection（SkyAtmosphereLightDirection）保持一致。
	// 平行光沿自身 Forward 发射光线，指向光源的方向为 -Forward。
	FVector LightDir = DirectionalLight->GetActorForwardVector();
	if (UMMDAnchorRecorderSettings::ShouldInvertLightDirection())
	{
		LightDir = -LightDir;
	}
	LightDir.Normalize();

	// 4. V_cam：物体中心 → 相机（每帧常量，与 shader 端
	//    GetWorldCameraOrigin - GetObjectWorldPosition 一致）。
	//    ⚠ 这不是逐像素的 CameraDirectionVector —— AI 特征必须用整帧统一的 V_cam，
	//      否则参数会在屏幕上漂移，且 (LdotV, L_up) 无法确定光向。
	FVector ViewDir = CameraLocation - TargetActor->GetActorLocation();
	if (!ViewDir.Normalize())
	{
		Notify(TEXT("相机位置与选中物体重合，无法确定 V_cam"), false);
		return;
	}

	// 5. v6 特征：LdotV / L_up / L_right
	//    UE5 的 FVector 是双精度，DotProduct / .Z 都返回 double，显式收窄到 float，
	//    与批量导出路径（ExportAnchorsFromSequence）保持一致。
	const float LdotV = static_cast<float>(FVector::DotProduct(LightDir, ViewDir));
	const float LUp = static_cast<float>(LightDir.Z);

	// 角色右方 = cross(Up, V_cam)，与 shader / Python / 批量导出三处逐字一致；
	// 叉积退化时回退 +X（三处必须同值，否则特征空间对不上且不报错）。
	FVector Right = FVector::CrossProduct(FVector(0.0, 0.0, 1.0), ViewDir);
	if (!Right.Normalize())
	{
		Right = FVector(1.0, 0.0, 0.0);
	}
	const float LRight = static_cast<float>(FVector::DotProduct(LightDir, Right));

	// 6. 找含 MMD 参数的材质槽位 —— 与参考原点校验共用同一判据
	//    （CollectMMDMaterialSlots）。旧版这里有一份内联的重复实现，两处判据一旦
	//    漂移，就会出现「录制认得出材质、导出却认不出参考原点」这类难查的问题。
	TArray<FMMDMaterialSlot> Slots;
	CollectMMDMaterialSlots(TargetActor, Slots);
	if (Slots.Num() == 0)
	{
		Notify(TEXT("选中物体的任何材质槽位都未找到含 ShadowSmooth / ShadowLocation / ExposureScale 的 MaterialInstance"), false);
		return;
	}
	// 取第一个匹配槽位（与旧版遍历顺序一致：先 MeshComponent、后 slot）
	const FMMDMaterialSlot& First = Slots[0];
	const float   SS = First.ShadowSmooth;
	const float   SL = First.ShadowLocation;
	const float   EX = First.ExposureScale;
	const int32   FoundSlotIndex  = First.Slot;
	const FString FoundMaterialName = First.Material->GetName();
	if (Slots.Num() > 1)
	{
		FString Joined;
		for (int32 i = 0; i < Slots.Num(); ++i)
		{
			Joined += FString::Printf(TEXT("\n  %d) %s"), i + 1, *Slots[i].Describe());
		}
		Notify(FString::Printf(TEXT("检测到 %d 个含 MMD 参数的材质槽位：%s\n\n本次记录第一个：%s"),
			Slots.Num(), *Joined, *FoundMaterialName), false);
	}

	// 7. 合法性校验。
	//    ⚠ 旧版的 LxSq = 1 - LdotV^2 - L_up^2 >= 0 检查已删除 —— 该式只在「V 恒为 (0,1,0)」
	//      的前提下才成立。v5 起 LdotV = dot(L, V_cam)，而
	//          max(LdotV^2 + L_up^2) = 1 + |V_cam · Z|   （可达 1.57，仰角 35° 时）
	//      所以该检查会把合法配置误判为非法，例如太阳与相机同在上方时
	//      LdotV=1、L_up=1 → LxSq=-1 → 明明正常的顶光俯视构图被拒绝录制。
	//      真正需要防的退化情形（相机与物体重合）已在第 4 步拦掉。

	// 8. 追加锚点
	const FString CsvPath = UMMDAnchorRecorderSettings::GetAnchorsCsvPath();
	const FString Note = FString::Printf(TEXT("recordedV6 LdotV=%.2f L_up=%.2f L_right=%.2f"),
		LdotV, LUp, LRight);
	const FString Line = FString::Printf(TEXT("%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%s"),
		LdotV, LUp, LRight, SS, SL, EX, ViewDir.X, ViewDir.Y, ViewDir.Z, *Note);

	if (!AppendLineToCsv(CsvPath, Line))
	{
		Notify(FString::Printf(TEXT("写入 anchors.csv 失败：%s"), *CsvPath), false);
		return;
	}

	const FString SuccessMessage = FString::Printf(
		TEXT("已追加锚点 → %s\n\n材质: %s (slot %d)\nLdotV=%.2f   L_up=%.2f   L_right=%.2f\nSS=%.2f   SL=%.2f   EX=%.2f\n\n请运行 AIControl/retrain_all.py 重新训练并同步 MLP 权重"),
		*CsvPath, *FoundMaterialName, FoundSlotIndex, LdotV, LUp, LRight, SS, SL, EX);
	Notify(SuccessMessage, true);
}

void FMMDAnchorRecorderEditor::ExportAnchorsFromSequence()
{
	using namespace MMDAnchorRecorderPrivate;

	if (!GEditor)
	{
		Notify(TEXT("GEditor 无效"), false);
		return;
	}

	// 1. 当前打开的 Level Sequence（注意：请先在 Sequencer 编辑器里打开目标序列）
	ULevelSequence* LevelSequence = ULevelSequenceEditorBlueprintLibrary::GetCurrentLevelSequence();
	if (!LevelSequence)
	{
		Notify(TEXT("未找到当前打开的 Level Sequence，请先在 Sequencer 中打开目标序列"), false);
		return;
	}

	UMovieScene* MovieScene = LevelSequence->GetMovieScene();
	if (!MovieScene)
	{
		Notify(TEXT("Level Sequence 没有 MovieScene"), false);
		return;
	}

	const FFrameRate TickResolution = MovieScene->GetTickResolution();
	const FFrameRate DisplayRate = MovieScene->GetDisplayRate();
	UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: TickResolution=%s DisplayRate=%s"),
		*TickResolution.ToPrettyText().ToString(), *DisplayRate.ToPrettyText().ToString());

	// 2. 光：绑定 DirectionalLight 的 Transform 旋转通道
	const FGuid LightGuid = FindLightBindingGuid(MovieScene);
	if (!LightGuid.IsValid())
	{
		Notify(TEXT("找不到绑定 DirectionalLight 的 Transform 轨道"), false);
		return;
	}
	FMovieSceneDoubleChannel* RotChannels[3] = { nullptr, nullptr, nullptr };
	if (!GetTransformChannels(MovieScene, LightGuid, TEXT("Rotation"), RotChannels))
	{
		Notify(TEXT("光的 Transform 轨道中没有可读取的旋转通道"), false);
		return;
	}

	// 2b. 相机 binding。v5 起特征约定为 LdotV = dot(L, V_cam)，V_cam = 物体中心 → 相机，
	//     与 shader 端 (GetWorldCameraOrigin - GetObjectWorldPosition) 严格一致。
	//     注意这里**不要求**相机轨道有关键帧 —— 见 2d。
	const FGuid CameraGuid = FindCameraBindingGuid(MovieScene);
	const FString CameraName = CameraGuid.IsValid()
		? GetBindingName(MovieScene, CameraGuid)
		: FString();

	// 2c. 参考原点：**承载 MMD 材质**的选中 Actor 的位置。
	//     必须与 shader 端 GetObjectWorldPosition 取同一个点（即承载 MMD 材质的
	//     MeshComponent 所在 Actor 的原点），否则 V_cam 会有系统性偏差。
	//
	//     ⚠ 旧版直接取 Selected[0] 且不做任何校验。实际踩过：在 Sequencer 里调光的
	//       关键帧时灯处于选中状态，导出器就把位于世界原点的 DirectionalLight 当成了
	//       角色原点，V_cam 偏 36.9°、Right 偏 38.2°，25 个锚点全部落进错误的特征
	//       空间 —— 而训练指标一切正常，不报任何错，直到上机才发现全错。
	//     现在按材质判据严格筛选：选中项里必须**恰好一个**承载 MMD 材质才继续，
	//     否则中止导出并说明原因。宁可拒绝，也不猜。
	TArray<AActor*> OriginCandidates;
	TArray<FString>  NonMMDNames;
	CollectSelectedMMDActors(OriginCandidates, NonMMDNames);

	if (OriginCandidates.Num() != 1)
	{
		Notify(FString::Printf(
			TEXT("导出中止：%s\n\n"
				"V_cam 的参考原点必须是承载 MMD 材质的角色 Actor（需暴露 ShadowSmooth /\n"
				"ShadowLocation / ExposureScale 三个参数）。取错会让整张锚点表落进错误的\n"
				"特征空间，而且不会报任何错 —— 训练指标正常，上机全错。\n\n"
				"请只选中角色 Actor 后重新导出。"),
			*DescribeOriginSelectionFailure(OriginCandidates, NonMMDNames)), false);
		return;
	}

	AActor* TargetActor = OriginCandidates[0];
	const FVector TargetLocation = TargetActor->GetActorLocation();
	UE_LOG(LogTemp, Log,
		TEXT("MMDAnchorRecorder: 参考原点 Actor = '%s' (%.1f, %.1f, %.1f) —— 已校验其承载 MMD 材质"),
		*TargetActor->GetName(), TargetLocation.X, TargetLocation.Y, TargetLocation.Z);

	// 2d. V_cam（物体中心 → 相机）：整段导出只解析一次。
	//
	//     本管线是「相机不动、光源动」，相机轨道常常**有轨道但一个关键帧都没有**
	//     （相机是静止机位，不需要动画）。旧版对每个锚点求值 Translation 通道并据此算
	//     V_cam，在这种常态下每次求值都是 0 → 得到零向量 → 整张锚点表被打进错误的
	//     特征空间，而且没有任何报错。
	//
	//     改成三级解析，逐级降级但绝不静默：
	//       1) 关卡里按绑定名找相机 Actor，用它的当前世界位置（静止机位下这就是真相）
	//       2) 求值相机 Translation 通道的最早关键帧（相机轨道确实有关键帧时）
	//       3) 设置里的 V_cam 兜底
	//     解出的 V_cam 会进日志、也会进最终通知，导出后必须核对。
	FVector ViewDir = FVector::ZeroVector;
	FString VCamSource;
	bool bHaveCamLocation = false;
	FVector CamLocation = FVector::ZeroVector;

	if (AActor* CamActor = FindActorByBindingName(TargetActor->GetWorld(), CameraName))
	{
		CamLocation = CamActor->GetActorLocation();
		bHaveCamLocation = true;
		VCamSource = FString::Printf(TEXT("关卡相机 Actor '%s' 的当前位置"), *CamActor->GetName());
	}
	else if (CameraGuid.IsValid())
	{
		FMovieSceneDoubleChannel* CamLocChannels[3] = { nullptr, nullptr, nullptr };
		if (GetTransformChannels(MovieScene, CameraGuid, TEXT("Translation"), CamLocChannels))
		{
			TSet<FFrameNumber> CamTimes;
			for (int32 i = 0; i < 3; ++i)
			{
				CollectTimes(CamLocChannels[i], CamTimes);
			}
			if (CamTimes.Num() > 0)
			{
				TArray<FFrameNumber> SortedCamTimes = CamTimes.Array();
				SortedCamTimes.Sort();
				CamLocation = FVector(
					EvalDouble(CamLocChannels[0], SortedCamTimes[0]),
					EvalDouble(CamLocChannels[1], SortedCamTimes[0]),
					EvalDouble(CamLocChannels[2], SortedCamTimes[0]));
				bHaveCamLocation = true;
				VCamSource = FString::Printf(
					TEXT("相机 Translation 通道首个关键帧（tick %d）"), SortedCamTimes[0].Value);
			}
		}
	}

	if (bHaveCamLocation)
	{
		ViewDir = CamLocation - TargetLocation;
		if (!ViewDir.Normalize())
		{
			UE_LOG(LogTemp, Warning,
				TEXT("MMDAnchorRecorder: 相机位置 %s 与参考原点 %s 重合，无法确定 V_cam，改用兜底"),
				*CamLocation.ToString(), *TargetLocation.ToString());
			bHaveCamLocation = false;
		}
	}

	if (!bHaveCamLocation)
	{
		ViewDir = UMMDAnchorRecorderSettings::GetFallbackVCam();
		VCamSource = FString::Printf(
			TEXT("⚠ 兜底常量 %s（既没在关卡里找到相机 Actor '%s'，其 Translation 通道也没有关键帧）"),
			*ViewDir.ToString(), *CameraName);
		UE_LOG(LogTemp, Warning, TEXT("MMDAnchorRecorder: V_cam 走兜底 —— %s"), *VCamSource);
	}

	UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: V_cam = (%.4f, %.4f, %.4f)  来源：%s"),
		ViewDir.X, ViewDir.Y, ViewDir.Z, *VCamSource);

	// 3. MPC：三个 Shader 标量参数轨道
	FMovieSceneFloatChannel* MpcChannels[3] = { nullptr, nullptr, nullptr };
	if (!GetMpcScalarChannels(MovieScene, MpcChannels))
	{
		Notify(TEXT("MPC 轨道中找不到 ShadowSmooth / ShadowLocation / ExposureScale 三个标量参数"), false);
		return;
	}

	// 4. 关键帧时间并集作为锚点（光的旋转 3 通道 + MPC 的 3 个标量通道）
	TSet<FFrameNumber> KeyTimeSet;
	for (int32 i = 0; i < 3; ++i)
	{
		CollectTimes(RotChannels[i], KeyTimeSet);
		CollectTimes(MpcChannels[i], KeyTimeSet);
	}
	if (KeyTimeSet.Num() == 0)
	{
		Notify(TEXT("没找到任何关键帧，请在 Sequencer 里为光和 MPC 打关键帧"), false);
		return;
	}

	TArray<FFrameNumber> KeyTimes = KeyTimeSet.Array();
	KeyTimes.Sort();

	// 5. 逐锚点求值
	const bool bInvertLight = UMMDAnchorRecorderSettings::ShouldInvertLightDirection();
	TArray<FString> BodyLines;
	for (const FFrameNumber& TickTime : KeyTimes)
	{
		// 旋转：Roll/Pitch/Yaw = RX/RY/RZ（TickResolution 下求值）
		const double Roll = EvalDouble(RotChannels[0], TickTime);
		const double Pitch = EvalDouble(RotChannels[1], TickTime);
		const double Yaw = EvalDouble(RotChannels[2], TickTime);

		// FRotator 构造顺序为 (Pitch, Yaw, Roll)
		const FRotator LightRotation(Pitch, Yaw, Roll);
		FVector LightDir = LightRotation.Vector(); // Actor Forward（+X）
		if (bInvertLight)
		{
			LightDir = -LightDir; // 指向光源的方向，与材质 LightDirection 对齐
		}
		LightDir.Normalize();

		// v6 特征：LdotV = dot(L, V_cam)，L_up = L.Z，L_right = dot(L, Right)
		const float LdotV = static_cast<float>(FVector::DotProduct(LightDir, ViewDir));
		const float LUp = static_cast<float>(LightDir.Z);

		// 角色右方 = cross(Up, V_cam)。与 shader 端 Rgt、Python 侧 RIGHT 必须逐字一致：
		// 相机与 Up 平行时叉积退化为零向量，三处都回退到 +X —— 兜底值不同的话，同一组
		// 光照在训练集与运行时会被映射到不同的特征，且不会报错。
		FVector Right = FVector::CrossProduct(FVector(0.0, 0.0, 1.0), ViewDir);
		if (!Right.Normalize())
		{
			Right = FVector(1.0, 0.0, 0.0);
		}
		const float LRight = static_cast<float>(FVector::DotProduct(LightDir, Right));

		const float SS = EvalFloat(MpcChannels[0], TickTime);
		const float SL = EvalFloat(MpcChannels[1], TickTime);
		const float EX = EvalFloat(MpcChannels[2], TickTime);

		// 把 TickResolution 帧号转成 DisplayRate 帧号，与 Sequencer 时间轴一致
		const FFrameTime DisplayTime = FFrameRate::TransformTime(FFrameTime(TickTime), TickResolution, DisplayRate);
		const int32 DisplayFrame = DisplayTime.FrameNumber.Value;

		UE_LOG(LogTemp, Log, TEXT("MMDAnchorRecorder: tick=%d display=%d rot=(%.2f,%.2f,%.2f) dir=(%.3f,%.3f,%.3f) LdotV=%.3f L_up=%.3f L_right=%.3f SS=%.3f SL=%.3f EX=%.3f"),
			TickTime.Value, DisplayFrame, Pitch, Yaw, Roll, LightDir.X, LightDir.Y, LightDir.Z, LdotV, LUp, LRight, SS, SL, EX);

		// note = "<序列名> frame=<显示帧号>"。
		// 带序列名是因为采集约定是「每个光照角度 = 一个独立的 Level Sequence」，
		// 导出时按该前缀累积成多圈；不带名字的话各圈的帧号会互相重复
		// （每圈都有 frame=0/30/45…），合并后既分不清来源、也无法按序列替换旧行。
		//
		// 格式版本不再靠 note 标记（旧版写死 "seqV6 frame=.."）：v6 与否由 CSV 表头
		// 承载，collect_training_data.py 的 load_anchors() 按**表头**判定并报错，
		// 前几列列数相同（v5/v6 都是 6 列数据）时列数检查根本拦不住，标记靠不住。
		const FString Note = FString::Printf(TEXT("%s frame=%d"),
			*LevelSequence->GetName(), DisplayFrame);
		// V_cam 逐行落盘（本轮导出全部行同值）。它是这一行所在特征空间的唯一凭据 ——
		// 只有人能判断它解对了没有，因为它是否走了兜底、原点是不是角色，文件本身看不出。
		BodyLines.Add(FString::Printf(TEXT("%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%s"),
			LdotV, LUp, LRight, SS, SL, EX, ViewDir.X, ViewDir.Y, ViewDir.Z, *Note));
	}

	// 6. 合并写 anchors.csv：保留其它序列的行，替换本序列的旧行
	const FString CsvPath = UMMDAnchorRecorderSettings::GetAnchorsCsvPath();
	const FString SequenceName = LevelSequence->GetName();
	int32 ReplacedRows = 0;
	int32 KeptRows = 0;
	if (!MergeAnchorsCsv(CsvPath, SequenceName, BodyLines, ReplacedRows, KeptRows))
	{
		Notify(FString::Printf(TEXT("写入 anchors.csv 失败：%s"), *CsvPath), false);
		return;
	}
	UE_LOG(LogTemp, Log,
		TEXT("MMDAnchorRecorder: anchors.csv 合并完成 —— 序列 '%s' 写入 %d 行，"
		     "替换本序列旧行 %d 行，保留其它序列 %d 行"),
		*SequenceName, BodyLines.Num(), ReplacedRows, KeptRows);

	// V_cam 一定要出现在通知里：它决定了整张锚点表落在哪个特征空间，
	// 而它是否解对了（尤其是走了兜底的情况）只有人能判断。必须与
	// collect_training_data.py 打印的 V_cam 以及 shader 端的实际取值核对。
	const bool bVCamFromFallback = VCamSource.StartsWith(TEXT("⚠"));
	Notify(FString::Printf(
		TEXT("已从 Level Sequence '%s' 导出 %d 个锚点（v6 特征：LdotV / L_up / L_right）→ %s\n"
			"锚点表合并：替换本序列旧行 %d 行，保留其它序列 %d 行\n\n"
			"V_cam = (%.4f, %.4f, %.4f)\n  来源：%s\n\n"
			"光 binding:   %s\n相机 binding: %s\n参考原点:     %s\n\n"
			"请核对上面的 V_cam 与 collect_training_data.py 打印的 V_cam 一致，\n"
			"然后运行 AIControl/retrain_all.py 重新训练并同步 MLP 权重"),
		*SequenceName, BodyLines.Num(), *CsvPath, ReplacedRows, KeptRows,
		ViewDir.X, ViewDir.Y, ViewDir.Z, *VCamSource,
		*LightGuid.ToString(),
		CameraGuid.IsValid() ? *CameraGuid.ToString() : TEXT("(无)"),
		*TargetActor->GetName()), !bVCamFromFallback);
}