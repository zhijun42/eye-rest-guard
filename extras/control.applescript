on run
    try
        do shell script "pkill -USR1 -x eye_rest_guard"
    on error
        try
            do shell script "launchctl kickstart gui/$(id -u)/com.zhijun.eye_rest_guard"
            delay 0.8
            do shell script "pkill -USR1 -x eye_rest_guard"
        on error
            display alert "护眼守卫未运行" message "无法自动启动，请检查 LaunchAgent com.zhijun.eye_rest_guard。"
        end try
    end try
end run
