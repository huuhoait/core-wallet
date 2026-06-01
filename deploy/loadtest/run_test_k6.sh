export BASE_URL=http://localhost:8100
export REPORT=deploy/loadtest/reports/k6_datetime_300peak_600s_$(date +%Y%m%d_%H%M%S).md
sh deploy/loadtest/k6.sh -e PEAK=300 -e DURATION=600

