import UIKit

/// A local pointer remains responsive when a remote stream is static or omits the cursor.
/// The arrow tip, rather than the center of its image, is the remote click hotspot.
@MainActor final class RemoteCursorView: UIView {
  static let hotspot = CGPoint(x: 2, y: 2)
  private let arrow = CAShapeLayer()

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 34))
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    backgroundColor = .clear
    let path = UIBezierPath()
    path.move(to: Self.hotspot)
    for point in [CGPoint(x: 2, y: 25), CGPoint(x: 8, y: 19),
                  CGPoint(x: 13, y: 30), CGPoint(x: 17, y: 28),
                  CGPoint(x: 12, y: 18), CGPoint(x: 22, y: 18)] {
      path.addLine(to: point)
    }
    path.close()
    arrow.path = path.cgPath
    arrow.fillColor = UIColor.white.cgColor
    arrow.strokeColor = UIColor.black.cgColor
    arrow.lineWidth = 1.5
    arrow.lineJoin = .round
    arrow.shadowColor = UIColor.black.cgColor
    arrow.shadowOpacity = 0.4
    arrow.shadowRadius = 1.5
    arrow.shadowOffset = CGSize(width: 0, height: 1)
    layer.addSublayer(arrow)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func place(tip: CGPoint, visible: Bool) {
    // Cursor movement must not animate behind finger movement or network input.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    frame.origin = CGPoint(x: tip.x - Self.hotspot.x, y: tip.y - Self.hotspot.y)
    isHidden = !visible
    CATransaction.commit()
  }
}
