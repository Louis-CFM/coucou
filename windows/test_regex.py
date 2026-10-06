import re

html = open('ddg_lite.html', encoding='utf-8').read()
matches = re.findall(r'(?is)<a[^>]*href="([^"]+)"[^>]*class=[\'"]result-link[\'"][^>]*>(.*?)</a>.*?<td[^>]*class=[\'"]result-snippet[\'"][^>]*>(.*?)</td>', html)
for m in matches[:3]:
    print(m)
print(len(matches))
