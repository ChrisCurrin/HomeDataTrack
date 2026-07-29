import sys
import time
from datetime import datetime
from firebase import firebase
from html.parser import HTMLParser
from PyQt4.QtGui import *
from PyQt4.QtCore import *
from PyQt4.QtWebKit import *


class MyHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.result = dict()
        self.active = False
        self.names = ['night', 'day', 'wifi']
        self.nameI = 0

    def handle_data(self, data):
        if data == 'Included Telkom Mobile Night Surfer Data' or data == 'Inclusive SmartBroadband Data' or data == 'Wi-Fi Data Unlimited Speed':
            self.active = True
            self.wait = 3
            self.name = self.names[self.nameI]
            self.nameI += 1
        if data == '':
            self.active = False
        if self.active:
            self.wait -= 1
            if self.wait == 0:
                self.result[self.name] = data

    def get_result(self):
        return self.result

    def error(self, message):
        pass


# Rendering is required to finish javascript loading of information
class Render(QWebPage):
    def __init__(self, url):
        QWebPage.__init__(self)
        self.frame = None
        self.mainFrame().loadFinished.connect(self._loadFinished)
        self.mainFrame().load(QUrl(url))

    def _loadFinished(self, result):
        self.frame = self.mainFrame()


class _Getch:
    """Gets a single character from standard input.  Does not echo to the
screen."""

    def __init__(self):
        try:
            self.impl = _GetchWindows()
        except ImportError:
            self.impl = _GetchUnix()

    def __call__(self):
        return self.impl()


class _GetchUnix:
    def __init__(self):
        import tty, sys

    def __call__(self):
        import sys, tty, termios
        fd = sys.stdin.fileno()
        old_settings = termios.tcgetattr(fd)
        try:
            tty.setraw(sys.stdin.fileno())
            ch = sys.stdin.read(1)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
        return ch


class _GetchWindows:
    def __init__(self):
        import msvcrt

    def __call__(self):
        import msvcrt
        return msvcrt.getch()


try:
    from config import Config
    web_url, secret, firebaseUrl = Config.getConfig()
    print("using values from a config file")
except ImportError:
    print("using example values")
    web_url = 'https://randomwebsite.com'
    secret = '123456789'
    firebaseUrl = 'https://random.firebaseio.com'

authentication = firebase.FirebaseAuthentication(secret, 'example@example.com')  # dummy password
firebaseApp = firebase.FirebaseApplication(firebaseUrl, authentication)
app = QApplication(sys.argv)
getch = _Getch()

# firebase.authentication = authentication
print(authentication.extra)
sleepMin = 60
sleepHalfHour = sleepMin * 30
sleepHour = sleepMin * 60

ctime = datetime.now()
print(ctime)
formatted_time = ctime.isoformat()
hour_min = formatted_time[11:16]
hour = int(hour_min[0:2])
date = formatted_time[0:10]
year_month = date[0:7]
day = date[8:10]


def go_again():
    global r, timer, year_month, day, hour_min, hour, ctime
    print("do again")
    ctime = datetime.now()
    print(ctime)
    formatted_time = ctime.isoformat()
    hour_min = formatted_time[11:16]
    hour = int(hour_min[0:2])
    date = formatted_time[0:10]
    year_month = date[0:7]
    day = date[8:10]

    r = Render(web_url)
    timer.start(2000)


def check_done():
    global r, timer, year_month, day, hour_min, hour, ctime
    if r.frame is not None:
        timer.stop()
        html_result = r.frame.toHtml()
        parser = MyHTMLParser()
        parser.feed(html_result)
        final = parser.get_result()
        print(final)
        firebaseApp.put('/' + year_month + '/' + day, hour_min, final)
        time2 = datetime.now()
        time_taken = (time2 - ctime).total_seconds()
        # for i in range(int(sleepHalfHour - time_taken)):
        #    time.sleep(1)
        #    print(i)
        if 0 < hour < 8:
            time.sleep((sleepHour*2-time_taken))  # check less at night
        else:
            time.sleep(sleepHalfHour-time_taken)  # check every period (less time_taken seconds)
        go_again()


go = False
r = Render(web_url)
timer = QTimer()
timer.timeout.connect(check_done)
timer.start(2000)

sys.exit(app.exec_())
