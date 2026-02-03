// Only compiled on Web due to conditional import from stub.
import 'dart:html' as html;
import 'dart:typed_data';

void downloadPdfBytesWeb(Uint8List pdfBytes, String fileName) {
  final blob = html.Blob([pdfBytes], "application/pdf");
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..click();
  html.Url.revokeObjectUrl(url);
}
