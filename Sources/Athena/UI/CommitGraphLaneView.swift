// CommitGraphLaneView.swift
// Athena — draws one row of the commit graph from a `GitGraphRow`.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - CommitGraphLaneView

struct CommitGraphLaneView: View {
    let row: GitGraphRow
    let maxLanes: Int
    let height: CGFloat

    nonisolated static let laneWidth: CGFloat = 12

    private nonisolated static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red]

    private nonisolated func color(_ lane: Int) -> Color { Self.palette[lane % Self.palette.count] }
    private nonisolated func x(_ lane: Int) -> CGFloat { CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2 }

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            func line(_ from: CGPoint, _ to: CGPoint, _ lane: Int) {
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(color(lane)), lineWidth: 1.5)
            }
            for lane in row.passThroughLanes {
                line(CGPoint(x: x(lane), y: 0), CGPoint(x: x(lane), y: size.height), lane)
            }
            for lane in row.incomingLanes {
                line(CGPoint(x: x(lane), y: 0), CGPoint(x: x(row.lane), y: mid), lane)
            }
            for lane in row.outgoingLanes {
                line(CGPoint(x: x(row.lane), y: mid), CGPoint(x: x(lane), y: size.height), lane)
            }
            let r: CGFloat = 4
            let node = CGRect(x: x(row.lane) - r, y: mid - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: node), with: .color(color(row.lane)))
        }
        .frame(width: CGFloat(max(1, maxLanes)) * Self.laneWidth, height: height)
    }
}
