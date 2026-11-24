// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause

#include <linux/delay.h>
#include <linux/firmware.h>
#include <linux/nvmem-consumer.h>

#include "core.h"
#include "debug.h"
#include "reg.h"
#include "rtw89_factory.h"

#define RTW89_FACTORY_CELL_NAME		"wifi-calibration"
#define RTW89_FACTORY_MAGIC		"TYFC0003"
#define RTW89_FACTORY_MIN_LEN		0x11c

#define RTW89_FACTORY_CAL_OFF_GAIN	0x08
#define RTW89_FACTORY_CAL_OFF_THERM	0x0d
#define RTW89_FACTORY_CAL_OFF_XTAL	0x0f
#define RTW89_FACTORY_CAL_OFF_TSSI	0x10
#define RTW89_FACTORY_CAL_OFF_MAC	0x42
#define RTW89_FACTORY_CAL_OFF_DIFF	0x48

static struct rtw89_factory_cal rtw89_factory_cals[RTW89_FACTORY_RADIO_NUM];
static bool rtw89_factory_loaded[RTW89_FACTORY_RADIO_NUM];

static int rtw89_factory_nvmem_read(struct rtw89_dev *rtwdev, const char *name,
				    u8 **buf, size_t *len)
{
	struct nvmem_cell *cell;
	void *data;

	cell = nvmem_cell_get(rtwdev->dev, name);
	if (IS_ERR(cell))
		return PTR_ERR(cell);

	data = nvmem_cell_read(cell, len);
	nvmem_cell_put(cell);
	if (IS_ERR(data))
		return PTR_ERR(data);

	*buf = data;

	return 0;
}

static void rtw89_factory_parse_radio(struct rtw89_factory_cal *cal,
				      const u8 *blk, size_t len)
{
	u32 i, j, ofst;

	if (len < RTW89_FACTORY_MIN_LEN ||
	    memcmp(blk, RTW89_FACTORY_MAGIC, 8) != 0)
		return;

	cal->valid = true;

	cal->gain_valid = false;
	for (i = 0; i < 5; i++) {
		u8 data = blk[RTW89_FACTORY_CAL_OFF_GAIN + i];

		if (data == 0xff)
			continue;

		cal->gain_valid = true;
		cal->gain_offset[RF_PATH_A][i] =
			sign_extend32(u8_get_bits(data, GENMASK(7, 4)), 3);
		cal->gain_offset[RF_PATH_B][i] =
			sign_extend32(u8_get_bits(data, GENMASK(3, 0)), 3);
	}

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		cal->thermal[i] = blk[RTW89_FACTORY_CAL_OFF_THERM + i];

	cal->xtal = blk[RTW89_FACTORY_CAL_OFF_XTAL];

	cal->tssi_valid = false;
	ofst = RTW89_FACTORY_CAL_OFF_TSSI;
	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_CCK_NUM; j++) {
			cal->tssi_cck[i][j] = (s8)blk[ofst++];
			if (cal->tssi_cck[i][j] != (s8)0xff)
				cal->tssi_valid = true;
		}

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_MCS_2G_NUM; j++)
			cal->tssi_mcs_2g[i][j] = (s8)blk[ofst++];

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_MCS_5G_NUM; j++)
			cal->tssi_mcs_5g[i][j] = (s8)blk[ofst++];

	ether_addr_copy(cal->mac, blk + RTW89_FACTORY_CAL_OFF_MAC);

	ofst = RTW89_FACTORY_CAL_OFF_DIFF;
	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_DIFF_NUM; j++) {
			cal->tssi_gain_diff[i][j] =
				(s8)blk[ofst + i * RTW89_FACTORY_TSSI_DIFF_NUM + j];
			cal->tssi_cw_diff[i][j] =
				(s8)blk[ofst + (RTW89_FACTORY_PATH_NUM + i) * RTW89_FACTORY_TSSI_DIFF_NUM + j];
		}

}

struct rtw89_factory_cal *rtw89_factory_cal_get(struct rtw89_dev *rtwdev,
						enum rtw89_factory_radio radio)
{
	struct rtw89_factory_cal *cal;
	u8 *buf;
	size_t len;
	int ret;

	if (radio >= RTW89_FACTORY_RADIO_NUM)
		return NULL;

	cal = &rtw89_factory_cals[radio];
	if (rtw89_factory_loaded[radio])
		return cal->valid ? cal : NULL;

	ret = rtw89_factory_nvmem_read(rtwdev, RTW89_FACTORY_CELL_NAME,
				       &buf, &len);
	if (!ret) {
		rtw89_factory_parse_radio(cal, buf, len);
		kfree(buf);
	}

	if (cal->valid)
		rtw89_debug(rtwdev, RTW89_DBG_FW,
			    "factory radio%d valid=%d mac=%pM xtal=0x%x thermal=%d/%d gain=%d tssi=%d\n",
			    radio, cal->valid, cal->mac, cal->xtal,
			    cal->thermal[RF_PATH_A], cal->thermal[RF_PATH_B],
			    cal->gain_valid, cal->tssi_valid);
	else
		rtw89_debug(rtwdev, RTW89_DBG_FW,
			    "factory radio%d not available ret=%d\n",
			    radio, ret);

	if (!cal->valid)
		memset(cal, 0, sizeof(*cal));

	rtw89_factory_loaded[radio] = true;

	return cal->valid ? cal : NULL;
}

void rtw89_factory_fill_efuse(struct rtw89_efuse *efuse,
			      struct rtw89_factory_cal *cal)
{
	if (is_valid_ether_addr(cal->mac)) {
		ether_addr_copy(efuse->addr, cal->mac);
		efuse->valid = true;
	}

	if (cal->xtal != 0xff)
		efuse->xtal_cap = cal->xtal;
}

void rtw89_factory_fill_gain(struct rtw89_dev *rtwdev,
			     struct rtw89_factory_cal *cal)
{
	struct rtw89_phy_efuse_gain *gain = &rtwdev->efuse_gain;
	u8 path, i;

	if (!cal->gain_valid)
		return;

	for (path = 0; path < RTW89_FACTORY_PATH_NUM; path++)
		for (i = 0; i < RTW89_GAIN_OFFSET_NR; i++)
			gain->offset[path][i] = cal->gain_offset[path][i];
	gain->offset_valid = true;
}

void rtw89_factory_fill_tssi(struct rtw89_dev *rtwdev,
			     struct rtw89_factory_cal *cal)
{
	struct rtw89_tssi_info *tssi = &rtwdev->tssi;
	u8 i;

	if (!cal->tssi_valid)
		return;

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++) {
		if (cal->thermal[i] != 0xff)
			tssi->thermal[i] = cal->thermal[i];
		memcpy(tssi->tssi_cck[i], cal->tssi_cck[i],
		       RTW89_FACTORY_TSSI_CCK_NUM);
		memcpy(tssi->tssi_mcs[i], cal->tssi_mcs_2g[i],
		       RTW89_FACTORY_TSSI_MCS_2G_NUM);
		memcpy(tssi->tssi_mcs[i] + RTW89_FACTORY_TSSI_MCS_2G_NUM,
		       cal->tssi_mcs_5g[i], RTW89_FACTORY_TSSI_MCS_5G_NUM);
	}
}

/* PT1570-R10 board RF front-end needs the vendor NCTL array before the
 * first H2C/C2H handshake.  This is a 1:1 port of the vendor rtl_ax_ap
 * sequence (rf-start.h: rtl_ax_rf_nctl_start): trigger NCTL at 0x18000,
 * poll 0x18080 up to 1000 times but continue regardless, then write the
 * register pairs with the PHY base 0x10000 added.  Delays 0xf9..0xfe are
 * opcode markers in the vendor array, not real registers.
 */
#define RTW89_FACTORY_NCTL_CFG		0x18000
#define RTW89_FACTORY_NCTL_STS		0x18080
#define RTW89_FACTORY_NCTL_PHY_BASE	0x10000

static u32 rtw89_factory_le32(const u8 *p)
{
	return (u32)p[0] | ((u32)p[1] << 8) |
	       ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

void rtw89_factory_nctl_start(struct rtw89_dev *rtwdev)
{
	static const u32 delay_us[6] = { 1, 5, 50, 1000, 5000, 50000 };
	const struct firmware *fw;
	unsigned int pairs, i;
	const char *name;
	u32 cv;
	int ret;

	switch (rtwdev->chip->chip_id) {
	case RTL8852C:
		cv = (rtw89_read32(rtwdev, 0x00f0) >> 12) & 0xf;
		name = cv ? "realtek/tyfza1/array_mp_8852c_nctl_reg.bin"
			  : "realtek/tyfza1/array_mp_8852c_nctl_reg_a.bin";
		pairs = cv ? 1782 : 1769;
		break;
	case RTL8192XB:
		cv = 0;
		name = "realtek/tyfza1/array_mp_8192xb_nctl_reg.bin";
		pairs = 1421;
		break;
	default:
		return;
	}

	ret = request_firmware(&fw, name, rtwdev->dev);
	if (ret) {
		rtw89_info(rtwdev, "factory NCTL %s request failed ret=%d\n",
			   name, ret);
		return;
	}
	if (fw->size != pairs * 8) {
		rtw89_info(rtwdev, "factory NCTL %s size=%zu expected=%u\n",
			   name, fw->size, pairs * 8);
		release_firmware(fw);
		return;
	}

	/* Vendor preamble: force IQK/DPK path clocks, then trigger NCTL. */
	rtw89_write32_mask(rtwdev, 0x10c60, 0x3, 0x3);
	rtw89_write32_set(rtwdev, 0x10c6c, BIT(0));
	rtw89_write32_set(rtwdev, 0x158ac, BIT(27));
	rtw89_write32_set(rtwdev, 0x178ac, BIT(27));
	rtw89_write32(rtwdev, RTW89_FACTORY_NCTL_CFG, 8);

	/* Vendor polls 1000 times and continues even if the block never
	 * reports ready -- deliberately not a hard failure. */
	for (i = 0; i < 1000; i++) {
		rtw89_write32(rtwdev, RTW89_FACTORY_NCTL_STS, 4);
		udelay(1);
		if (rtw89_read32(rtwdev, RTW89_FACTORY_NCTL_STS) == 4)
			break;
	}

	for (i = 0; i < pairs; i++) {
		u32 addr = rtw89_factory_le32(fw->data + i * 8);
		u32 data = rtw89_factory_le32(fw->data + i * 8 + 4);

		if (addr >= 0xf9 && addr <= 0xfe)
			udelay(delay_us[addr - 0xf9]);
		else
			rtw89_write32(rtwdev,
				      addr | RTW89_FACTORY_NCTL_PHY_BASE,
				      data);
	}
	release_firmware(fw);

	rtw89_info(rtwdev, "factory NCTL %s pairs=%u cv=%u poll=%u done\n",
		   name, pairs, cv, i);
}
