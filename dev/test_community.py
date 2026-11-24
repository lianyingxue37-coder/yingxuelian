"""在本地 HTTP 服务验证双账号消息和运营后台操作。"""
import os
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

URL = os.environ.get("URL", "http://127.0.0.1:8765/index.html")
ORIGIN = URL.rsplit("/", 1)[0]
MOCK = Path(__file__).with_name("mock-supabase.js")


def main():
    with sync_playwright() as p:
        chrome = os.environ.get("CHROME")
        browser = p.chromium.launch(**({"executable_path": chrome} if chrome else {}))
        ctx = browser.new_context(viewport={"width": 844, "height": 390}, service_workers="block")
        ctx.route("**/*", lambda route: route.continue_() if route.request.url.startswith(ORIGIN + "/") else route.abort())
        ctx.add_init_script(path=MOCK)
        errors = []
        players = [ctx.new_page(), ctx.new_page()]
        for i, player in enumerate(players):
            player.on("pageerror", lambda error: errors.append(str(error)))
            player.goto(URL)
            player.wait_for_function("DUANLIAN.ACC.state === 'out'")
            player.locator("[data-go=PG_WORLD]").click()
            expect(player.get_by_text("登录后即可发送消息", exact=False)).to_be_visible()
            player.evaluate(
                "([user, nick]) => DUANLIAN.accSignUp(user, 'community-test', nick, 'CH_JIN')",
                ["world_" + str(i), "频道玩家" + str(i)],
            )
            expect(player.locator("#worldInput")).to_be_visible()

        a, b = players
        a.locator("#worldInput").fill("<img> 大家好")
        a.get_by_role("button", name="发送", exact=True).click()
        expect(b.locator("#worldMessages")).to_contain_text("<img> 大家好")
        expect(b.locator("#worldMessages b")).to_have_text("频道玩家0")
        expect(b.locator("#worldMessages img")).to_have_count(0)
        b.locator("#worldInput").fill("收到")
        b.locator("#worldInput").press("Enter")
        expect(a.locator("#worldMessages")).to_contain_text("收到")
        b.locator("#PG_WORLD [data-go=PG_TITLE]").click()
        b.locator("[data-go=PG_WORLD]").click()
        expect(b.locator("#worldMessages li")).to_have_count(2)
        b.get_by_role("button", name="加入全服语音").click()
        expect(b.locator("#worldVoiceStatus")).to_have_text("语音服务即将上线。")

        admin = ctx.new_page()
        admin.on("pageerror", lambda error: errors.append(str(error)))
        admin.goto(ORIGIN + "/admin/?demo=1")
        admin.locator("[data-page=accounts]").click()
        target = admin.locator("tr").filter(has_text="@lianying").get_by_role("button", name="管理账号")
        target.click()
        dialog = admin.locator("#player-dialog")
        expect(dialog).to_be_visible()
        dialog.locator("#player-reason").fill("发放测试外观")
        dialog.locator("[data-player-action=grant_item] select").select_option("SHOP_PORTRAITS")
        dialog.get_by_role("button", name="发放", exact=True).click()
        expect(dialog.locator("li")).to_contain_text("全角色立绘组合包")
        dialog.locator("#player-reason").fill("退回测试道具")
        dialog.get_by_role("button", name="收回", exact=True).click()
        expect(dialog.get_by_text("暂无道具")).to_be_visible()
        dialog.locator("#player-reason").fill("测试禁言")
        dialog.get_by_role("button", name="全服文字禁言").click()
        expect(dialog.get_by_text("已禁言", exact=True)).to_be_visible()
        dialog.locator("#player-reason").fill("还原昵称")
        dialog.get_by_label("昵称").fill("活动玩家")
        dialog.get_by_role("button", name="保存资料").click()
        expect(dialog.locator("#player-title")).to_contain_text("活动玩家")
        dialog.get_by_role("button", name="关闭").click()
        admin.locator("[data-page=audit]").click()
        expect(admin.get_by_text("发放测试外观")).to_be_visible()
        assert not errors, errors
        print("world chat and admin UI passed")
        browser.close()


if __name__ == "__main__":
    main()
