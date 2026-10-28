import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// Blip's own tray glyph (net.blip.Blip-offline-symbolic.svg, 24x24 viewBox),
// filled with the theme colour like the other bar marks.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    width: 24
    height: 24
    scale: root.iconSize / 24
    transformOrigin: Item.TopLeft
    // Curve renderer keeps the edges crisp at any scale; a layer would be
    // rasterised at 24px and blur in the panel hero.
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.color
      fillRule: ShapePath.OddEvenFill
      strokeWidth: 0
      PathSvg { path: "M5.227,2.967C5.35,2.268 5.412,1.918 5.588,1.656C5.744,1.425 5.962,1.242 6.217,1.129C6.505,1 6.86,1 7.57,1L16.341,1C17.316,1 17.803,1 18.149,1.199C18.451,1.374 18.683,1.65 18.803,1.979C18.939,2.353 18.854,2.833 18.685,3.793L18.403,5.4L21.519,5.4C22.006,5.4 22.25,5.4 22.422,5.499C22.574,5.587 22.69,5.725 22.75,5.889C22.818,6.076 22.775,6.316 22.691,6.796L22.335,8.817C22.274,9.167 22.243,9.341 22.154,9.473C22.076,9.588 21.968,9.679 21.84,9.736C21.696,9.801 21.518,9.801 21.163,9.801H17.625L16.85,14.2L19.967,14.2C20.454,14.2 20.698,14.2 20.87,14.299C21.022,14.387 21.137,14.524 21.197,14.689C21.265,14.876 21.223,15.116 21.139,15.596L20.783,17.617C20.721,17.966 20.691,18.141 20.602,18.272C20.524,18.388 20.415,18.479 20.288,18.536C20.143,18.6 19.966,18.6 19.611,18.6H16.073L15.644,21.033C15.521,21.732 15.46,22.082 15.283,22.344C15.127,22.575 14.909,22.758 14.655,22.871C14.366,23 14.01,23 13.3,23L4.529,23C3.554,23 3.067,23 2.722,22.801C2.419,22.626 2.187,22.35 2.068,22.021C1.931,21.647 2.016,21.167 2.185,20.206L5.227,2.967ZM16.073,18.599L16.848,14.2H8.78C8.425,14.2 8.247,14.2 8.103,14.265C7.975,14.321 7.866,14.413 7.788,14.528C7.7,14.659 7.669,14.834 7.608,15.184L7.252,17.203C7.168,17.683 7.125,17.923 7.194,18.11C7.253,18.274 7.369,18.413 7.521,18.5C7.693,18.6 7.937,18.6 8.424,18.6L16.073,18.599ZM18.401,5.401L17.625,9.8L9.976,9.8C9.489,9.8 9.245,9.8 9.073,9.7C8.921,9.613 8.806,9.475 8.746,9.311C8.678,9.123 8.72,8.883 8.804,8.404L9.16,6.384C9.222,6.035 9.252,5.86 9.341,5.729C9.419,5.613 9.528,5.522 9.655,5.465C9.799,5.401 9.977,5.401 10.332,5.401H18.401Z" }
    }
  }
}
