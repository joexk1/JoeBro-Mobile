import ActivityKit
import SwiftUI
import WidgetKit
import UIKit

@main
struct JoeBroIslandBundle: WidgetBundle {
    var body: some Widget {
        JoeBroIslandWidget()
    }
}

struct JoeBroIslandWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JoeBroActivityAttributes.self) { context in
            JoeBroLockScreenActivity(state: context.state, isStale: context.isStale)
                .background { activityBackdrop(scene: context.attributes.sceneName) }
                .activityBackgroundTint(IslandInk.bg)
                .activitySystemActionForegroundColor(islandTint)
                .widgetURL(URL(string: context.attributes.destination))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandMark(text: islandMark(context.state), tint: statusColor(context.state), size: 24)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.finished == nil {
                        Text(context.state.startedAt, style: .timer)
                            .font(.islandMono(11))
                            .foregroundStyle(IslandInk.ink3)
                            .frame(maxWidth: 48, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.state, stale: context.isStale))
                        .font(.islandSans(15, .semibold))
                        .foregroundStyle(IslandInk.ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    JoeBroExpandedIslandContent(state: context.state)
                }
            } compactLeading: {
                Text(islandMark(context.state)).font(.islandMono(11, .semibold)).foregroundStyle(statusColor(context.state))
            } compactTrailing: {
                if context.state.finished != nil {
                    Circle().fill(statusColor(context.state)).frame(width: 7, height: 7)
                } else {
                    HStack(spacing: 4) {
                        IslandDots(value: context.state.count, dot: 1.8, tint: IslandInk.ink)
                        Circle().fill(statusColor(context.state)).frame(width: 6, height: 6)
                    }
                }
            } minimal: {
                if context.state.finished != nil {
                    Circle().fill(statusColor(context.state)).frame(width: 8, height: 8)
                } else {
                    ZStack(alignment: .topTrailing) {
                        IslandDots(value: context.state.count, dot: 1.8, tint: IslandInk.ink)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Circle().fill(statusColor(context.state)).frame(width: 5, height: 5)
                    }
                }
            }
            .keylineTint(statusColor(context.state))
            .widgetURL(URL(string: context.attributes.destination))
        }
    }
}
