class CogCli < Formula
  desc "Tools for AI coding"
  homepage "https://github.com/bcardarella/cog-cli"
  license "MIT"
  head "https://github.com/bcardarella/cog-cli.git", branch: "main"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe"
    bin.install "zig-out/bin/cog"
  end

  test do
    output = shell_output("#{bin}/cog --help 2>&1")
    assert_match "Tools for AI coding", output
    assert_match "Usage:", output
  end
end