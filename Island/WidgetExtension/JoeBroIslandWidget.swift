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
                .activityBackgroundTint(context.attributes.sceneName.map { $0 != "off" } == true
                                        ? Color.black
                                        : Color(red: 0.12, green: 0.08, blue: 0.22).opacity(0.85))
                .activitySystemActionForegroundColor(islandTint)
                .widgetURL(URL(string: context.attributes.destination))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: glyph(context.state))
                        .font(.system(size: 18))
                        .foregroundStyle(islandTint)
                        .frame(width: 24, height: 24)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.finished == nil {
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(.caption, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.65))
                            .frame(maxWidth: 48, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.state, stale: context.isStale))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    JoeBroExpandedIslandContent(state: context.state)
                }
            } compactLeading: {
                Image(systemName: glyph(context.state)).foregroundStyle(islandTint)
            } compactTrailing: {
                if context.state.finished != nil {
                    Image(systemName: glyph(context.state)).foregroundStyle(statusColor(context.state))
                } else {
                    HStack(spacing: 3) {
                        Text("\(context.state.count)")
                            .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Circle().fill(statusColor(context.state)).frame(width: 7, height: 7)
                    }
                }
            } minimal: {
                if context.state.finished != nil {
                    Image(systemName: glyph(context.state)).foregroundStyle(statusColor(context.state))
                } else {
                    ZStack(alignment: .topTrailing) {
                        Text("\(context.state.count)")
                            .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Circle().fill(statusColor(context.state)).frame(width: 6, height: 6)
                    }
                }
            }
            .keylineTint(statusColor(context.state))
            .widgetURL(URL(string: context.attributes.destination))
        }
    }
}

