// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (C) 2008-2012, OPPO Mobile Comm Corp., Ltd
 * Copyright (c) 2025-2026 Ricky Cheung <rcheung844@gmail.com>
 */

#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/gpio/consumer.h>
#include <linux/power_supply.h>
#include <linux/delay.h>
#include <linux/mutex.h>
#include <linux/of.h>

#include <linux/power/oppo_gauge.h>
#include <linux/power/oppo_vooc.h>

void vooc_set_fast_charge_enabled(struct oppo_vooc_device *vooc, bool enabled)
{
	int i;
	int values[vooc->switch_gpios->ndescs];

	for (i = 0; i < vooc->switch_gpios->ndescs; i++)
		values[i] = enabled;

	vooc->fast_charge_enabled = enabled;
	gpiod_set_array_value_cansleep(vooc->switch_gpios->ndescs,
				       vooc->switch_gpios->desc, values);
}

void vooc_chip_step_clock(struct oppo_vooc_device *vooc) {
	gpiod_set_value_cansleep(vooc->clock_gpio, 0);
	usleep_range(1000, 1000);

	gpiod_set_value_cansleep(vooc->clock_gpio, 1);
	usleep_range(19000, 19000);
}

void vooc_chip_send_reply(struct oppo_vooc_device *vooc, int reply_info)
{
	int device_type = 0;

#ifdef CONFIG_BATTERY_GAUGE_OPPO_BQ27541
	if (bq27541_device_type >= 0)
		device_type = bq27541_device_type;
#endif

	// Set data GPIOs to sleep (output)
	gpiod_direction_output(vooc->data_gpio, 0);

	// Send data through data GPIOs
	gpiod_set_value_cansleep(vooc->data_gpio, reply_info >> 1);
	vooc_chip_step_clock(vooc);
	gpiod_set_value_cansleep(vooc->data_gpio, reply_info & 0x1);
	vooc_chip_step_clock(vooc);
	gpiod_set_value_cansleep(vooc->data_gpio, device_type);
	vooc_chip_step_clock(vooc);

	// Set data GPIOs to active (input)
	gpiod_direction_input(vooc->data_gpio);
}

static void vooc_reset_mcu(struct oppo_vooc_device *vooc)
{
	dev_dbg(vooc->dev, "reset mcu\n");

	// Put clock to sleep
	gpiod_set_value_cansleep(vooc->clock_gpio, 1);
	usleep_range(19000, 19000);

	// Perform reset operation
	gpiod_set_value_cansleep(vooc->reset_gpio, 0);
	usleep_range(5000, 5000);
	gpiod_set_value_cansleep(vooc->reset_gpio, 1);
	usleep_range(10000, 10000);
	gpiod_set_value_cansleep(vooc->reset_gpio, 0);
	usleep_range(5000, 5000);
}

static void vooc_poll_func(struct work_struct *work)
{
	int i, data, bit;
	int chip_reply_info = 2; // FIXME: May also be returning 1
	struct oppo_vooc_device *vooc = container_of(work,
			struct oppo_vooc_device, vooc_poll_work);
	struct device *dev = vooc->dev;

	dev_dbg(vooc->dev, "poll mcu\n");

	usleep_range(2000, 2000);
	if (!mutex_trylock(&vooc->lock))
		return;

	disable_irq(vooc->data_irq);

	// Check if data received start with "101"
	for (i = 0; i < 7; i++) {
		vooc_chip_step_clock(vooc);
		bit = gpiod_get_value_cansleep(vooc->data_gpio);
		data |= bit << (6 - i);

		if (i == 2 && data != 0x50 && !vooc->fw_update_required) {
			if (!vooc->fast_charge_enabled)
				goto out;

			dev_err(dev, "received errornous data: 0x%x\n", data);
			vooc_set_fast_charge_enabled(vooc, false);
			// TODO!
		}
	}

	dev_dbg(dev, "received data: 0x%x, fw version: 0x%x\n",
		 data, vooc->fw_data_version);

	switch (data) {
	case VOOC_NOTIFY_FAST_PRESENT:
		vooc_set_fast_charge_enabled(vooc, true);
		break;
	case VOOC_NOTIFY_FAST_ABSENT:
		vooc_set_fast_charge_enabled(vooc, false);
		break;
	case VOOC_NOTIFY_ALLOW_READING_IIC:
		// TODO: Investigate whatever this does
		dev_info(dev, "chip reported to allowing reading i2c\n");
		break;
	case VOOC_NOTIFY_LOW_TEMP_FULL:
	case VOOC_NOTIFY_BAD_CONNECTED:
	case VOOC_NOTIFY_TEMP_OVER:
	case VOOC_NOTIFY_BTB_TEMP_OVER:
		dev_err(dev, "chip reported error, data: 0x%x\n", data);
	case VOOC_NOTIFY_NORMAL_TEMP_FULL:
		vooc_set_fast_charge_enabled(vooc, false);
		break;
	case VOOC_NOTIFY_FIRMWARE_UPDATE:
	case VOOC_NOTIFY_ADAPTER_FW_UPDATE:
		// TODO: Implement firmware update
		dev_info(dev, "chip reported for fw update\n");
		break;
	default:
		dev_err(dev, "received errornous data: 0x%x\n", data);
		vooc_set_fast_charge_enabled(vooc, false);
		break;
	}

	msleep(2);
	vooc_chip_send_reply(vooc, chip_reply_info);
out:
	vooc_chip_step_clock(vooc);
	enable_irq(vooc->data_irq);
	mutex_unlock(&vooc->lock);
}

static irqreturn_t vooc_irq_rx_handler(int irq, void *data)
{
	struct oppo_vooc_device *vooc = data;
	schedule_work(&vooc->vooc_poll_work);
	return IRQ_HANDLED;
}

static void adapter_update_func(struct work_struct *work)
{
	struct oppo_vooc_device *vooc = container_of(work,
			struct oppo_vooc_device, adapter_update_work);

	msleep(20);
	vooc_set_fast_charge_enabled(vooc, false);
	vooc_reset_mcu(vooc);

	gpiod_set_value_cansleep(vooc->clock_gpio, 0);
	msleep(10);
	gpiod_set_value_cansleep(vooc->reset_gpio, 0);
	msleep(2500);
	gpiod_set_value_cansleep(vooc->clock_gpio, 1);
	// TODO: Perform fw checks here

	msleep(5);
	gpiod_set_value_cansleep(vooc->reset_gpio, 0);
}

static bool vooc_is_batt_psy_available(struct oppo_vooc_device *vooc)
{
	if (!vooc->batt_psy)
		vooc->batt_psy = power_supply_get_by_name("battery");

	if (!vooc->batt_psy)
		return false;

	return true;
}

static void power_supply_changed_func(struct work_struct *work)
{
	int rc;
	union power_supply_propval pval = {0,};
	struct oppo_vooc_device *vooc = container_of(work,
			struct oppo_vooc_device, power_supply_changed_work);

	if (vooc_is_batt_psy_available(vooc)) {
		rc = power_supply_get_property(vooc->batt_psy,
					       POWER_SUPPLY_PROP_STATUS, &pval);
		if (rc < 0)
			dev_err(vooc->dev,
				"Error obtaining battery status, rc=%d\n", rc);

		if (pval.intval == POWER_SUPPLY_STATUS_CHARGING)
			schedule_work(&vooc->adapter_update_work);
	} else {
		dev_err(vooc->dev, "Error obtaining battery power supply");
	}
}

static int vooc_psy_notifier_cb(struct notifier_block *nb,
				 unsigned long event, void *data)
{
	struct power_supply *psy = data;
	struct oppo_vooc_device *vooc = container_of(nb, struct oppo_vooc_device, nb);

	if (strcmp(psy->desc->name, "battery") == 0) {
		pm_stay_awake(vooc->dev);
		schedule_work(&vooc->power_supply_changed_work);
	}

	return NOTIFY_OK;
}

static int vooc_probe(struct i2c_client *client,
		      const struct i2c_device_id *id)
{
	int rc = 0;

	struct oppo_vooc_device *vooc = devm_kzalloc(&client->dev,
						     sizeof(*vooc), GFP_KERNEL);
	if (!vooc) {
		dev_err(&client->dev, "no memory\n");
		rc = -ENOMEM;
		goto out;
	}

	vooc->client = client;
	vooc->dev = &client->dev;
	i2c_set_clientdata(client, vooc);

	vooc->switch_gpios = devm_gpiod_get_array(&client->dev,
			"switch", GPIOD_OUT_LOW);
	if (IS_ERR(vooc->switch_gpios)) {
		rc = PTR_ERR(vooc->switch_gpios);
		dev_err(&client->dev,
			"Failed to request GPIO switch pins, error rc=%d\n", rc);
		goto out;
	}

	vooc->reset_gpio = devm_gpiod_get(&client->dev,
				"reset", GPIOD_OUT_LOW);
	if (IS_ERR(vooc->reset_gpio)) {
		rc = PTR_ERR(vooc->reset_gpio);
		dev_err(&client->dev,
			"Failed to request GPIO reset pin, error rc=%d\n", rc);
		goto out;
	}

	vooc->clock_gpio = devm_gpiod_get(&client->dev,
				"clock", GPIOD_OUT_LOW);
	if (IS_ERR(vooc->clock_gpio)) {
		rc = PTR_ERR(vooc->clock_gpio);
		dev_err(&client->dev,
			"Failed to request GPIO clock pin, error rc=%d\n", rc);
		goto out;
	}

	vooc->data_gpio = devm_gpiod_get(&client->dev,
				"data", GPIOD_IN);
	if (IS_ERR(vooc->data_gpio)) {
		rc = PTR_ERR(vooc->data_gpio);
		dev_err(&client->dev,
			"Failed to request GPIO data pin, error rc=%d\n", rc);
		goto out;
	}

	vooc->data_irq = gpiod_to_irq(vooc->data_gpio);
	if (vooc->data_gpio < 0) {
		rc = vooc->data_irq;
		goto out;
	}

	vooc->batt_psy = power_supply_get_by_name("battery");
	if (vooc->batt_psy == NULL)
		dev_err(&client->dev,
			"Failed to get battery power supply rc=%d\n", rc);

	vooc->nb.notifier_call = vooc_psy_notifier_cb;
	rc = power_supply_reg_notifier(&vooc->nb);
	if (rc < 0)
		dev_err(&client->dev,
			"Error registering psy notifier rc = %d\n", rc);

	mutex_init(&vooc->lock);

	INIT_WORK(&vooc->vooc_poll_work, vooc_poll_func);
	INIT_WORK(&vooc->adapter_update_work, adapter_update_func);
	INIT_WORK(&vooc->power_supply_changed_work, power_supply_changed_func);

	rc = devm_request_irq(&client->dev, vooc->data_irq,
			      vooc_irq_rx_handler, IRQF_TRIGGER_RISING,
			      "vooc_mcu_data", vooc);
	if (rc < 0) {
		dev_err(&client->dev, "Request irq %d failed\n", vooc->data_irq);
		goto out;
	}

	return rc;

out:
	if (vooc)
		devm_kfree(&client->dev, (void *)vooc);
	return rc;
}

static int vooc_remove(struct i2c_client *client)
{
	struct oppo_vooc_device *vooc = i2c_get_clientdata(client);

	dev_dbg(&client->dev, "removed\n");
	if (!vooc)
		return 0;

	devm_kfree(&client->dev, (void *)vooc);

	return 0;
}

static const struct i2c_device_id vooc_i2c_ids[] = {
	{ "pic16f-vooc", 0 },
	{ "stm8s-vooc", 0 },
	{},
};
MODULE_DEVICE_TABLE(i2c, vooc_i2c_ids);

static const struct of_device_id vooc_of_match[] = {
	{ .compatible = "oppo,pic16f-vooc", },
	{ .compatible = "oppo,stm8s-vooc", },
	{}
};
MODULE_DEVICE_TABLE(of, vooc_of_match);

static struct i2c_driver vooc_i2c_driver = {
	.driver = {
		.name	= "vooc-charger",
		.owner	= THIS_MODULE,
		.of_match_table = vooc_of_match,
	},
	.probe	= vooc_probe,
	.remove	= vooc_remove,
	.id_table = vooc_i2c_ids,
};
module_i2c_driver(vooc_i2c_driver);

MODULE_DESCRIPTION("OPPO VOOC charging driver");
MODULE_AUTHOR("Ricky Cheung <rcheung844@gmail.com>");
MODULE_LICENSE("GPL v2");
