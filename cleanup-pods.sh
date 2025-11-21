kubectl delete pod --field-selector=status.phase==Succeeded -A

kubectl delete pod --field-selector=status.phase==Failed -A
