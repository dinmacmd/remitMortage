import fs from "fs";
import path from "path";

describe("Print-Optimized Stylesheet (#584)", () => {
  const printCssPath = path.join(__dirname, "../src/styles/print.css");
  const globalsCssPath = path.join(__dirname, "../src/app/globals.css");

  it("should have print.css file present", () => {
    expect(fs.existsSync(printCssPath)).toBe(true);
  });

  it("should import print.css in globals.css", () => {
    const globalsContent = fs.readFileSync(globalsCssPath, "utf8");
    expect(globalsContent).toContain('@import "../styles/print.css";');
  });

  it("should contain mandatory media print rules", () => {
    const printContent = fs.readFileSync(printCssPath, "utf8");

    // Must hide navigation bars, buttons, footers, and interactive chrome
    expect(printContent).toContain("@media print");
    expect(printContent).toContain("header,");
    expect(printContent).toContain("footer,");
    expect(printContent).toContain("nav,");
    expect(printContent).toContain("button,");
    expect(printContent).toContain("display: none !important;");

    // Must set clean page dimensions and white background
    expect(printContent).toContain("@page");
    expect(printContent).toContain("background: #ffffff !important;");

    // Must enforce table reflow and formatting
    expect(printContent).toContain("table {");
    expect(printContent).toContain("display: table-header-group !important;");

    // Must control page breaks
    expect(printContent).toContain("page-break-inside: avoid !important;");
    expect(printContent).toContain("break-inside: avoid !important;");
    expect(printContent).toContain(".page-break-before");
    expect(printContent).toContain(".avoid-page-break");
  });
});
