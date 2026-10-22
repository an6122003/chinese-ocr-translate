
VALID_SYLLABLES = set('''a ai an ang ao
ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
da dai dan dang dao de den deng di dian diao die ding diu dong dou du duan dui dun duo
e ei en eng er
fa fan fang fei fen feng fo fou fu
ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo
la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu long lou lu luan lue lun luo lv lve
ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nuo nv nve
o ou
pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
ran rang rao re ren reng ri rong rou ru ruan rui run ruo
sa sai san sang sao se sen seng sha shai shan shang shao she shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
wa wai wan wang wei wen weng wo wu
xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo'''.split())

TONE_MAP = {
    'ā':'a', 'á':'a', 'ǎ':'a', 'à':'a',
    'ē':'e', 'é':'e', 'ě':'e', 'è':'e',
    'ī':'i', 'í':'i', 'ǐ':'i', 'ì':'i',
    'ō':'o', 'ó':'o', 'ǒ':'o', 'ò':'o',
    'ū':'u', 'ú':'u', 'ǔ':'u', 'ù':'u',
    'ǖ':'ü', 'ǘ':'ü', 'ǚ':'ü', 'ǜ':'ü',
    'v': 'ü' # normalize 'v' to 'ü' as well where needed
}

def remove_tone_marks(text):
    """Removes tone marks from a string and converts v to ü for consistency"""
    for accented, base in TONE_MAP.items():
        text = text.replace(accented, base)
        text = text.replace(accented.upper(), base.upper())
    return text

def get_accented_pinyin(syllable, tone):
    """
    Takes a pinyin syllable (string) and a tone (int 1-4) 
    and returns the accented version based on standard rules.
    """
    vowels = {
        'a': ['ā', 'á', 'ǎ', 'à'],
        'e': ['ē', 'é', 'ě', 'è'],
        'i': ['ī', 'í', 'ǐ', 'ì'],
        'o': ['ō', 'ó', 'ǒ', 'ò'],
        'u': ['ū', 'ú', 'ǔ', 'ù'],
        'v': ['ǖ', 'ǘ', 'ǚ', 'ǜ'],
        'ü': ['ǖ', 'ǘ', 'ǚ', 'ǜ'],
    }
    
    tone_idx = int(tone) - 1
    if tone_idx < 0 or tone_idx > 3:
        return syllable + str(tone)

    # First cleanly remove any existing tone marks (so if the string is 'mā', it becomes 'ma')
    clean_syllable = remove_tone_marks(syllable)

    # Convert to list for mutation
    s_list = list(clean_syllable.lower())
    
    # Rule 1: 'a'
    if 'a' in s_list:
        idx = s_list.index('a')
        s_list[idx] = vowels['a'][tone_idx]
    # Rule 2: 'e' or 'o'
    elif 'e' in s_list:
        idx = s_list.index('e')
        s_list[idx] = vowels['e'][tone_idx]
    elif 'o' in s_list:
        idx = s_list.index('o')
        s_list[idx] = vowels['o'][tone_idx]
    # Rule 3: 'ui' or 'iu'
    elif 'iu' in clean_syllable.lower():
        idx = clean_syllable.lower().index('iu') + 1
        s_list[idx] = vowels['u'][tone_idx]
    elif 'ui' in clean_syllable.lower():
        idx = clean_syllable.lower().index('ui') + 1
        s_list[idx] = vowels['i'][tone_idx]
    # Rule 4: remaining vowels (i, u, v, ü)
    else:
        for char in reversed(s_list):
            if char in vowels:
                idx = clean_syllable.lower().rfind(char)
                s_list[idx] = vowels[char][tone_idx]
                break
        else:
            return clean_syllable + str(tone) # No vowel found
            
    result = "".join(s_list)
    if syllable[0].isupper():
        result = result.capitalize()
        
    return result

# Tests
if __name__ == "__main__":
    test_cases = [
        ("ma", 1, "mā"),
        ("na", 2, "ná"),
        ("na", 3, "nǎ"),
        ("bu", 4, "bù"),
        ("shuang", 1, "shuāng"),
        ("niu", 3, "niǔ"),
        ("tue", 4, "tuè"),
        ("lv", 3, "lǚ"),
    ]
    for syl, t, expected in test_cases:
        res = get_accented_pinyin(syl, t)
        print(f"{syl}{t} -> {res} (Expected: {expected})")
        assert res == expected
