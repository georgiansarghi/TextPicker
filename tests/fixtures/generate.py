"""Small deterministic SYNTHETIC screenshot-like corpus; not a public benchmark.
Font sizes are physical pixels; native CoreText rendering via render.swift.
No screen capture, private content, or uploaded images are involved.
"""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FONT_ROOT = Path('/System/Library/Fonts')
FONT = str(FONT_ROOT / 'Helvetica.ttc')
MONO = str(FONT_ROOT / 'Menlo.ttc')
CASES = [
    dict(id='english', group='latin', language='en', size=22, text='Capture text from anywhere on your screen.\nThe quick brown fox jumps over the lazy dog.\nOrder #A1042 costs $39.95 before tax.'),
    dict(id='german', group='latin', language='de', size=22, text='Grüße aus München! Öffnen Sie die Einstellungen.\nDie Straße führt über die Brücke zum Café.\nRechnungsbetrag: 1.234,56 € inkl. 19 % MwSt.'),
    dict(id='french_spanish', group='latin', language='fr+es', size=22, text='Éléonore préfère le café à la crème brûlée.\nOù se trouve la bibliothèque municipale ?\nEl próximo miércoles: información, año y corazón.'),
    dict(id='dark_ui', group='latin', language='en', size=16, dark=True, text='Settings  /  Privacy & Security\nScreen Recording permission is required.\nAllow this application to capture your screen.\nCancel     Open System Settings'),
    dict(id='tiny_ui', group='latin', language='en', size=11, text='Build completed successfully in 2.47 seconds.\n12 files changed, 148 insertions(+), 37 deletions(-)\nhttps://example.com/api/v2/items?limit=25&offset=0'),
    dict(id='code', group='latin', language='en', size=17, dark=True, font=MONO, text='const result = await fetch("/api/items?id=42");\nif (result.status !== 200) throw new Error("Failed");\nconst total = items.reduce((sum, x) => sum + x.price, 0);\nconsole.log({ count: items.length, total });'),
    dict(id='terminal', group='latin', language='en', size=15, font=MONO, text='$ git status --short\n M src/components/CaptureView.swift\n?? tests/ocr_accuracy_test.py\nError: ECONNREFUSED 127.0.0.1:8080'),
    dict(id='dense', group='latin', language='en', size=16, text='\n'.join(f'Item {i:02d}: local text recognition should finish without a network request.' for i in range(1,21))),
    dict(id='low_contrast', group='latin', language='en', size=18, fg='#929292', bg='#dedede', text='Your changes have been saved automatically.\nLast updated on 12 October 2026 at 09:41.\nCopy the selected text to the clipboard.'),
    dict(id='chinese', group='cjk', language='zh-Hans', size=26, font=str(FONT_ROOT/'Hiragino Sans GB.ttc'), text='屏幕文字识别可以在本地完成。\n请选择需要复制的文字区域。\n订单编号：20261012，价格：128元。'),
    dict(id='japanese', group='cjk', language='ja', size=26, font=str(next(FONT_ROOT.glob('*角*W3.ttc'))), text='画面上の文字をコピーできます。\n設定を開いて言語を選択してください。\n注文番号：20261012、合計：1280円。'),
    dict(id='korean', group='other', language='ko', size=26, font=str(FONT_ROOT/'AppleSDGothicNeo.ttc'), text='화면의 텍스트를 복사할 수 있습니다.\n설정을 열고 언어를 선택하세요.\n주문 번호: 20261012, 가격: 12800원.'),
    dict(id='russian', group='other', language='ru', size=24, text='Распознавание текста работает без интернета.\nОткройте настройки и выберите язык.\nНомер заказа: 20261012, цена: 1280 рублей.'),
    dict(id='arabic', group='other', language='ar', size=28, direction='rtl', font=str(FONT_ROOT/'GeezaPro.ttc'), text='يمكن نسخ النص من الشاشة\nافتح الإعدادات واختر اللغة\nالتعرف على النص يعمل بدون إنترنت'),
    dict(id='hindi', group='other', language='hi', size=28, font=str(FONT_ROOT/'Kohinoor.ttc'), text='स्क्रीन से पाठ कॉपी करें\nसेटिंग खोलें और भाषा चुनें\nयह सेवा बिना इंटरनेट के काम करती है'),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT.parents[1]/'.build/generated-fixtures')
    out = parser.parse_args().output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    manifest = [{**case, 'path': str(out/f"{case['id']}.png"), 'font': case.get('font', FONT)} for case in CASES]
    manifest_path = out/'manifest.json'
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    renderer = out/'FixtureRenderer'
    subprocess.run(['swiftc', '-O', str(ROOT/'render.swift'), '-o', str(renderer)], check=True)
    subprocess.run([str(renderer), str(manifest_path)], check=True)
    print(f'Generated {len(manifest)} synthetic cases in {out}')

if __name__ == '__main__':
    main()
