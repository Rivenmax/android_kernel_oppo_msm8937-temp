// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (C) 2008-2012, OPPO Mobile Comm Corp., Ltd
 * Copyright (c) 2025-2026 Ricky Cheung <rcheung844@gmail.com>
 */

#ifndef _OPPO_VOOC_H_
#define _OPPO_VOOC_H_

#include <linux/workqueue.h>

#define VOOC_NOTIFY_FAST_PRESENT			0x52
#define VOOC_NOTIFY_FAST_ABSENT				0x54
#define VOOC_NOTIFY_ALLOW_READING_IIC		0x58
#define VOOC_NOTIFY_NORMAL_TEMP_FULL		0x5a
#define VOOC_NOTIFY_LOW_TEMP_FULL			0x53
#define VOOC_NOTIFY_FIRMWARE_UPDATE			0x56
#define VOOC_NOTIFY_BAD_CONNECTED			0x59
#define VOOC_NOTIFY_TEMP_OVER				0x5c
#define VOOC_NOTIFY_ADAPTER_FW_UPDATE		0x5b
#define VOOC_NOTIFY_BTB_TEMP_OVER			0x5d

struct oppo_vooc_device {
	struct i2c_client *client;
	struct device *dev;
	struct mutex lock;

	struct power_supply *batt_psy;
	struct notifier_block nb;

	struct work_struct vooc_poll_work;
	struct work_struct adapter_update_work;
	struct work_struct power_supply_changed_work;

	struct gpio_descs *switch_gpios;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *clock_gpio;
	struct gpio_desc *data_gpio;
	int data_irq;

	int fw_data_version;

	bool fast_charge_enabled;
	bool fw_update_required;
};

#endif /* _OPPO_VOOC_H */
