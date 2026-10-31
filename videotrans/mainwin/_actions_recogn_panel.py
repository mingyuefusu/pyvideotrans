"""把"语音转录"面板嵌入主窗口 main_stack，替代默认的独立窗口打开方式。

配套改动：
- ui/menu_list.py 中 fn_recogn 菜单项第三列为 False（不再自动连 get_win）
- mainwin/_bind_signals.py 手工绑定 self.fn_recogn -> open_recogn_panel
- ui/en.py 主界面套 QStackedWidget(self.main_stack)
- mainwin/_actions_base_mode.py 的 set_biaozhun/set_tiquzimu 切回第0页
"""
from PySide6.QtWidgets import QScrollArea

from videotrans.configure.config import app_cfg


class WinActionRecognPanelMixin:

    def open_recogn_panel(self):
        # 复用 winform.fn_recogn.openwin() 的完整接线逻辑，但不再作为顶层窗口 show()
        win = app_cfg.child_forms.get('fn_recogn')
        if win is None:
            from videotrans.winform.fn_recogn import openwin
            win = openwin()
            app_cfg.child_forms['fn_recogn'] = win
            # 面板 setMinimumSize(1200,500)，套滚动区避免撑大主窗口
            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setWidget(win)
            self.main.main_stack.addWidget(scroll)
            # setWidget 后面板的 parent 是 viewport 而非滚动区，切换必须用滚动区本身
            self.recogn_panel_scroll = scroll
        if hasattr(win, 'update_ui'):
            win.update_ui()
        self.main.main_stack.setCurrentWidget(self.recogn_panel_scroll)
