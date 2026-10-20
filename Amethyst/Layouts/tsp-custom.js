// Tertiary Split Partition as a custom layout.
//
// The screen is divided three ways: a main pane in the middle with a side pane on each side, and each side pane is
// divided three ways again as windows arrive. A pane wider than it is tall divides into columns; a tall or square
// pane divides into rows. The first window fills the screen. The second takes the left or top side and the third the
// right or bottom side, a third each at the default ratio. Later windows divide the side panes into thirds the same
// way, level by level, always filling the left or top sides of a level before its right or bottom sides.

// How many sides of the main pane held windows the last time frames were assigned. A drag with one side occupied
// shows the ratio plus half of what the ratio leaves over, and the recommendation is converted back accordingly.
let mainPaneSideCount = 0;

function layout() {
    // The share of a divided side pane its own window keeps once both of its sides hold a window.
    const sidePaneMiddleRatio = 1 / 3;

    // A pane divides into columns when it is wider than it is tall, otherwise into rows.
    const axisDividing = (rect) => (rect.width > rect.height ? "columns" : "rows");
    const perpendicular = (axis) => (axis === "columns" ? "rows" : "columns");
    const length = (axis, rect) => (axis === "columns" ? rect.width : rect.height);

    // The part of `rect` that starts `offset` in along the axis and extends `extent`, spanning the other dimension.
    const slice = (axis, rect, offset, extent) =>
        axis === "columns"
            ? { x: rect.x + offset, y: rect.y, width: extent, height: rect.height }
            : { x: rect.x, y: rect.y + offset, width: rect.width, height: extent };

    // `count` equal parts of `rect` along the axis, rounded to whole points so that they tile it exactly.
    const divide = (axis, rect, count) => {
        const total = length(axis, rect);
        const parts = [];
        for (let index = 0; index < count; index++) {
            const start = Math.round((total * index) / count);
            const end = Math.round((total * (index + 1)) / count);
            parts.push(slice(axis, rect, start, end - start));
        }
        return parts;
    };

    // Panes are numbered in the order windows fill them. Node 0 is the root and holds the main pane. Numbers run
    // level by level: the root's left or top side is node 1 and its right or bottom side is node 2; each later level
    // numbers the left or top sides of the previous level's nodes in order, then their right or bottom sides. Side
    // window `k`, counting from zero, occupies node `k + 1`.
    const level = (node) => 31 - Math.clz32(node + 1);
    const firstSide = (node) => {
        const depth = level(node);
        const positionInLevel = node - ((1 << depth) - 1);
        return (1 << (depth + 1)) - 1 + positionInLevel;
    };
    const secondSide = (node) => firstSide(node) + (1 << level(node));

    // Divides the pane of `node` between its own window and the nodes on its sides that hold a window. Each occupied
    // side gets half of what the middle leaves, and the middle keeps the share of an empty side.
    const panes = (rect, node, sideWindowCount, middleRatio) => {
        const axis = axisDividing(rect);
        const hasFirst = firstSide(node) <= sideWindowCount;
        const hasSecond = secondSide(node) <= sideWindowCount;
        const total = length(axis, rect);
        const sideLength = Math.round((total * (1 - middleRatio)) / 2);
        const firstLength = hasFirst ? sideLength : 0;
        const secondLength = hasSecond ? sideLength : 0;
        const middleLength = total - firstLength - secondLength;
        return {
            axis,
            first: hasFirst ? slice(axis, rect, 0, firstLength) : null,
            middle: slice(axis, rect, firstLength, middleLength),
            second: hasSecond ? slice(axis, rect, firstLength + middleLength, secondLength) : null
        };
    };

    // Stores the frame of the window at `node` and of every window dividing it, indexed by side window.
    const assignFrames = (node, rect, sideWindowCount, frames) => {
        const divided = panes(rect, node, sideWindowCount, sidePaneMiddleRatio);
        frames[node - 1] = divided.middle;
        if (divided.first) {
            assignFrames(firstSide(node), divided.first, sideWindowCount, frames);
        }
        if (divided.second) {
            assignFrames(secondSide(node), divided.second, sideWindowCount, frames);
        }
    };

    const clamp = (ratio) => Math.max(0, Math.min(1, ratio));
    const resizeStep = (settings) => (settings && typeof settings.windowResizeStep === "number" ? settings.windowResizeStep : 0.05);

    return {
        name: "Tertiary Split Partition (custom)",
        initialState: {
            mainPaneCount: 1,
            mainPaneRatio: 1 / 3
        },
        commands: {
            increaseMain: {
                description: "Increase main pane count",
                updateState: (state) => ({ ...state, mainPaneCount: state.mainPaneCount + 1 })
            },
            decreaseMain: {
                description: "Decrease main pane count",
                updateState: (state) => ({ ...state, mainPaneCount: Math.max(1, state.mainPaneCount - 1) })
            },
            expandMain: {
                description: "Expand main pane",
                updateState: (state, focusedWindowID, settings) => ({ ...state, mainPaneRatio: clamp(state.mainPaneRatio + resizeStep(settings)) })
            },
            shrinkMain: {
                description: "Shrink main pane",
                updateState: (state, focusedWindowID, settings) => ({ ...state, mainPaneRatio: clamp(state.mainPaneRatio - resizeStep(settings)) })
            }
        },
        // Takes the share of the screen the main pane should have and stores the ratio that produces it.
        recommendMainPaneRatio: (ratio, state) => ({
            ...state,
            mainPaneRatio: clamp(mainPaneSideCount === 1 ? 2 * ratio - 1 : ratio)
        }),
        getFrameAssignments: (windows, screenFrame, state) => {
            const mainWindowCount = Math.min(state.mainPaneCount, windows.length);
            const sideWindowCount = windows.length - mainWindowCount;
            const root = panes(screenFrame, 0, sideWindowCount, state.mainPaneRatio);
            mainPaneSideCount = (root.first ? 1 : 0) + (root.second ? 1 : 0);

            // Main windows share the main pane, stacked across the direction of the split.
            const frames = divide(perpendicular(root.axis), root.middle, mainWindowCount);
            const sideFrames = new Array(sideWindowCount).fill(null);
            if (root.first) {
                assignFrames(firstSide(0), root.first, sideWindowCount, sideFrames);
            }
            if (root.second) {
                assignFrames(secondSide(0), root.second, sideWindowCount, sideFrames);
            }
            const allFrames = frames.concat(sideFrames);

            // Resizing any window is read as a change to the main pane's share of the screen along the root's axis.
            const screenLength = length(root.axis, screenFrame);
            const sideLength = (root.first ? length(root.axis, root.first) : 0) + (root.second ? length(root.axis, root.second) : 0);
            const unconstrainedDimension = root.axis === "columns" ? "horizontal" : "vertical";
            const mainScaleFactor = screenLength / Math.max(length(root.axis, root.middle), 1);
            const sideScaleFactor = screenLength / Math.max(sideLength, 1);

            return windows.reduce((result, window, index) => {
                const isMain = index < mainWindowCount;
                const frame = {
                    ...allFrames[index],
                    isMain,
                    unconstrainedDimension,
                    scaleFactor: isMain ? mainScaleFactor : sideScaleFactor
                };
                return { ...result, [window.id]: frame };
            }, {});
        }
    };
}
