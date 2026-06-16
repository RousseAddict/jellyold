import UIKit

class PosterCell: UICollectionViewCell {
    let posterView = AsyncImageView()
    let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        layer.cornerRadius = 6
        clipsToBounds = true
        backgroundColor = UIColor(white: 0.15, alpha: 1.0)

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        contentView.addSubview(posterView)

        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 11)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.backgroundColor = UIColor(white: 0.0, alpha: 0.65)
        contentView.addSubview(titleLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelH: CGFloat = 36
        posterView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - labelH)
        titleLabel.frame = CGRect(x: 0, y: bounds.height - labelH, width: bounds.width, height: labelH)
    }

    func configure(name: String, imageURL: String?) {
        titleLabel.text = name
        if let url = imageURL { posterView.load(url: url) } else { posterView.image = nil }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        posterView.cancel()
        posterView.image = nil
        titleLabel.text = nil
    }
}
