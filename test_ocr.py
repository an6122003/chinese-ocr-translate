import threading
import winocr
from PIL import Image
import io

img = Image.new('RGB', (100, 50), color = 'white')

def do_test(i):
    print(f"Running ocr {i}")
    op = winocr.recognize_pil(img, lang="en")
    op.wait(10)
    res = op.get_results()
    print(f"Ended ocr {i}: {res.text if res else ''}")

t1 = threading.Thread(target=do_test, args=(1,))
t1.start()
t1.join()

t2 = threading.Thread(target=do_test, args=(2,))
t2.start()
t2.join()

print("Success!")
